{ config, lib, pkgs, ... }:
let
  cfg = config.services.financeSignalProduction;
  app = config.services.homelab-mcp;
  mcp = config.systemd.services.homelab-mcp;
  signal = config.modules.services.signal-api;
  staging = config.systemd.services.finance-signal-capture-staging or { };
  dataDir = "/var/lib/homelab-mcp";
  database = "${dataDir}/finances-context.db";
  readerDir = "/run/finance-report-reader";
  reportDir = "${dataDir}/finance-reports";
  collector = "finance-signal-metrics";
  metricsDir = "/run/${collector}";
  transportSecret = "homelab-mcp/finance-signal-env";
  transportFile = config.sops.secrets.${transportSecret}.path or "/run/secrets/${transportSecret}";
  python = pkgs.python313.withPackages (ps: [ (ps.toPythonModule app.package) ]);
  helper = "${python}/bin/python3 -I -B ${./finance-signal-production/runtime.py}";
  notBefore = lib.escapeShellArg (if cfg.reportsNotBefore == null then "" else cfg.reportsNotBefore);
  mountGate = {
    RequiresMountsFor = [ dataDir ];
    AssertPathIsMountPoint = [ dataDir ];
  };
  oauthDb = mcp.environment.HOMELAB_MCP_OAUTH_STATE_DB_PATH or "${dataDir}/state.db";
  hidden = map (path: "-${path}") ([
    (mcp.environment.HOMELAB_MCP_OAUTH_SIGNING_KEY_PATH or "${dataDir}/signing-key.pem")
    "${dataDir}/finances"
    "${dataDir}/finances-state.json"
    "${dataDir}/finance-signal-staging"
    "${dataDir}/.env"
  ] ++ lib.concatMap (path: map (suffix: path + suffix) [ "" "-journal" "-wal" "-shm" ])
    [ oauthDb "${dataDir}/arcraiders.db" ]);
  sandbox = {
    User = mcp.serviceConfig.User;
    Group = mcp.serviceConfig.Group;
    UMask = "0077";
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    CapabilityBoundingSet = "";
    TemporaryFileSystem = [ "/var/lib:ro" "/run:ro" ];
    InaccessiblePaths = [ "-/run/secrets" "-/run/credentials" ] ++ hidden;
    MemoryMax = "512M";
    TasksMax = 64;
  };
in
{
  options.services.financeSignalProduction = {
    enable = lib.mkEnableOption "qualified deterministic Signal reports and canonical capture";
    reportsNotBefore = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "2026-10-01T00:00:00-04:00";
      description = "Explicit cutover instant with timezone; only scheduled slots at or after it are owed. Not a reminder or catch-up time.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The same existing secret is also declared by manual capture when installed.
    sops.secrets.${transportSecret} = {
      sopsFile = ../secrets.sops.yaml;
      owner = "root";
      group = "root";
      mode = "0400";
    };

    assertions = [
      {
        assertion = app.enable && lib.versionAtLeast (app.package.version or "0") "0.33.1";
        message = "finance-signal production requires MCP >= 0.33.1 with native capture/status and Ops-first durable report delivery.";
      }
      {
        assertion = !(config.systemd.services.hermes-agent.enable or true);
        message = "finance-signal production requires effective systemd.services.hermes-agent.enable=false. Keep the upstream Hermes module and backups declared; the parent retires runtime, schedules, recovery and heartbeat separately.";
      }
      {
        assertion = (staging.wantedBy or [ ]) == [ ]
          && (staging.requiredBy or [ ]) == [ ]
          && (staging.upheldBy or [ ]) == [ ]
          && lib.all
          (name:
            (config.systemd.timers.${name}.timerConfig.Unit or "${name}.service")
              != "finance-signal-capture-staging.service")
          (builtins.attrNames config.systemd.timers);
        message = "finance-signal production requires staging capture to have no autostart links or timer; stop staging before cutover.";
      }
      {
        assertion = cfg.reportsNotBefore != null
          && builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})" cfg.reportsNotBefore != null;
        message = "finance-signal production requires an explicit reportsNotBefore ISO-8601 cutover timestamp with timezone.";
      }
      {
        assertion = mcp.serviceConfig.User == "homelab-mcp"
          && mcp.serviceConfig.Group == "homelab-mcp"
          && mcp.environment.HOMELAB_MCP_FINANCES_CONTEXT_DB_PATH == database
          && config.modules.storage.datasets.services.homelab-mcp.mountpoint == dataDir
          && config.modules.services.backup.restic.jobs.homelab-mcp.enable
          && config.modules.services.backup.restic.jobs.homelab-mcp-offsite.enable;
        message = "finance-signal production must use the existing MCP UID, canonical context database and protected/backed-up dataset.";
      }
      {
        assertion = config.services.financeSignalStaging.reportReader.enable
          && (config.systemd.services.finance-report-reader-config.enable or false)
          && config.sops.secrets ? ${transportSecret}
          && config.sops.secrets.${transportSecret}.owner == "root"
          && config.sops.secrets.${transportSecret}.mode == "0400"
          && transportFile != app.environmentFile;
        message = "finance-signal production requires the existing native reader projection/peer role and parent-provisioned root-only five-key Signal environment; never the MCP environment.";
      }
      {
        assertion = signal.enable && signal.localAccess.enable
          && signal.localAccess.subnet != null
          && builtins.elem mcp.serviceConfig.User signal.localAccess.allowedUsers;
        message = "finance-signal production requires the existing Signal UID guard and configured DNAT subnet.";
      }
      {
        assertion = config.modules.monitoring.nodeExporter.enable
          && config.modules.monitoring.nodeExporter.textfileCollector.enable
          && builtins.elem "systemd" config.services.prometheus.exporters.node.enabledCollectors;
        message = "finance-signal production requires the existing node-exporter textfile and systemd collectors.";
      }
    ];

    systemd.services.finance-signal-capture = {
      description = "Deterministic household Signal note capture (no conversation)";
      wantedBy = [ "multi-user.target" ];
      conflicts = [ "hermes-agent.service" "finance-signal-capture-staging.service" ];
      after = [ "zfs-service-datasets.service" "podman-signal-api.service" "sops-install-secrets.service" ];
      requires = [ "zfs-service-datasets.service" "podman-signal-api.service" "sops-install-secrets.service" ];
      unitConfig = mountGate // { StartLimitIntervalSec = 600; StartLimitBurst = 3; };
      serviceConfig = sandbox // {
        Type = "simple";
        EnvironmentFile = [ transportFile ];
        ExecStart = "${helper} capture ${app.package}/bin/homelab-finances-signal ${toString signal.port}";
        # SQLite journals and both native leases are adjacent to the existing DB.
        # This is the same UID trust domain, not new credential isolation.
        BindPaths = [ dataDir ];
        ReadWritePaths = [ dataDir ];
        InaccessiblePaths = sandbox.InaccessiblePaths ++ [
          "-${reportDir}"
          "-${dataDir}/finances-ingest"
          "-/run/finance-report-reader"
          "-/run/postgresql"
        ];
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        IPAddressDeny = "any";
        IPAddressAllow = [ "127.0.0.1/32" "::1/128" ]
          ++ lib.optional (signal.localAccess.subnet != null) signal.localAccess.subnet;
        Restart = "on-failure";
        RestartSec = "30s";
        TimeoutStopSec = "60s";
        KillMode = "control-group";
      };
    };

    systemd.services."finance-signal-report@" = {
      description = "Native bounded %i finance report, Ops details before Family";
      after = [
        "zfs-service-datasets.service"
        "postgresql-provision-databases.service"
        "finance-report-reader-config.service"
        "podman-signal-api.service"
        "sops-install-secrets.service"
      ];
      requires = [
        "zfs-service-datasets.service"
        "postgresql-provision-databases.service"
        "finance-report-reader-config.service"
        "podman-signal-api.service"
        "sops-install-secrets.service"
      ];
      unitConfig = mountGate;
      path = [ pkgs.git ];
      environment = {
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        GIT_SSL_CAINFO = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };
      serviceConfig = sandbox // {
        Type = "oneshot";
        EnvironmentFile = [ transportFile ];
        ExecCondition = "${helper} due %i ${notBefore}";
        ExecStart = "${helper} report ${app.package}/bin/homelab-finances-signal-report %i ${toString signal.port} ${notBefore}";
        StateDirectory = "homelab-mcp/finance-reports";
        StateDirectoryMode = "0700";
        BindPaths = [ dataDir ];
        BindReadOnlyPaths = [ readerDir "/run/postgresql" "${dataDir}/finances-ingest" ];
        ReadWritePaths = [ dataDir ];
        ReadOnlyPaths = [ readerDir "${dataDir}/finances-ingest" ];
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        TimeoutStartSec = "270s";
        TimeoutStopSec = "45s";
        KillMode = "control-group";
        Restart = "no";
      };
    };

    systemd.timers = lib.genAttrs [ "finance-signal-report@daily" "finance-signal-report@weekly" ]
      (name: {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar =
            if lib.hasSuffix "@daily" name
            then "*-*-* 08:00,05,10:00 America/New_York"
            else "Fri *-*-* 16:00,05,10:00 America/New_York";
          Persistent = false;
          RandomizedDelaySec = 0;
          AccuracySec = "1s";
          Unit = "${name}.service";
        };
      }) // {
      ${collector} = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30s";
          OnUnitActiveSec = "2m";
          AccuracySec = "10s";
          Unit = "${collector}.service";
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d ${metricsDir} 2750 ${mcp.serviceConfig.User} node-exporter -"
      "L+ ${config.modules.monitoring.nodeExporter.textfileCollector.directory}/finance_signal.prom - - - - ${metricsDir}/finance_signal.prom"
    ];
    systemd.services.${collector} = {
      description = "Read-only local Signal listener/report evidence for node-exporter";
      after = [ "systemd-tmpfiles-setup.service" ];
      # No listener/CLI/mount dependency: missing state must still publish red.
      serviceConfig = sandbox // {
        Type = "oneshot";
        EnvironmentFile = [ transportFile ];
        ExecStart = "${helper} collect ${toString signal.port} ${notBefore} ${metricsDir}/finance_signal.prom";
        BindPaths = [ metricsDir ];
        BindReadOnlyPaths = [ "-${dataDir}" ];
        ReadOnlyPaths = [ "-${dataDir}" ];
        ReadWritePaths = [ metricsDir ];
        InaccessiblePaths = sandbox.InaccessiblePaths ++ [
          "-${reportDir}"
          "-${dataDir}/finances-ingest"
          "-/run/finance-report-reader"
          "-/run/postgresql"
        ];
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        TimeoutStartSec = "30s";
        Restart = "no";
      };
    };

    modules.alerting.rules = import ./finance-signal-production/alerts.nix {
      host = config.networking.hostName;
    };
  };
}
