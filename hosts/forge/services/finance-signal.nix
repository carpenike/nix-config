{ config, lib, pkgs, ... }:
let
  cfg = config.services.financeSignalStaging;
  app = config.services.homelab-mcp;
  mcp = config.systemd.services.homelab-mcp;
  signal = config.modules.services.signal-api;
  dataDir = "/var/lib/homelab-mcp";
  reportDir = "${dataDir}/finance-reports";
  readerDir = "/run/finance-report-reader";
  stagingDir = "${dataDir}/finance-signal-staging";
  productionDb = "${dataDir}/finances-context.db";
  readerRole = "finance-report-reader";
  transportSecret = "homelab-mcp/finance-signal-env";
  transportFile = config.sops.secrets.${transportSecret}.path or "/run/secrets/${transportSecret}";
  helper = "${pkgs.python3}/bin/python3 -I -B ${./finance-signal/runtime.py}";
  mountGate = {
    RequiresMountsFor = [ dataDir ];
    AssertPathIsMountPoint = [ dataDir ];
  };
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
    # Expose only explicitly bound state, not the other same-UID MCP stores.
    TemporaryFileSystem = [ "/var/lib:ro" "/run:ro" ];
    InaccessiblePaths = [
      "-/run/secrets"
      "-/run/credentials"
    ];
    MemoryMax = "512M";
    TasksMax = 64;
  };
in
{
  options.services.financeSignalStaging = {
    reportReader.enable = lib.mkEnableOption "manual native finance preparation (no delivery)";
    capture.enable = lib.mkEnableOption "manual Ops-only finance capture in an isolated test store";
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.reportReader.enable || cfg.capture.enable) {
      assertions = [
        {
          assertion = app.enable && lib.versionAtLeast (app.package.version or "0") "0.33.0";
          message = "finance-signal staging requires the paired MCP >= 0.33.0 native report/capture release; leave both gates off until repinned.";
        }
        {
          assertion = mcp.serviceConfig.User == "homelab-mcp"
            && mcp.serviceConfig.Group == "homelab-mcp"
            && mcp.environment.HOMELAB_MCP_FINANCES_CONTEXT_DB_PATH == productionDb;
          message = "finance-signal staging must retain the existing MCP identity and canonical production context path.";
        }
        {
          assertion = config.modules.storage.datasets.services.homelab-mcp.mountpoint == dataDir
            && config.modules.services.backup.restic.jobs.homelab-mcp.enable
            && config.modules.services.backup.restic.jobs.homelab-mcp-offsite.enable;
          message = "finance-signal staging must remain on the existing protected MCP dataset and backups.";
        }
      ];
    })

    (lib.mkIf cfg.reportReader.enable {
      services.postgresql.authentication = lib.mkBefore ''
        local homelab_finance ${readerRole} peer map=finance-report
      '';
      services.postgresql.identMap = lib.mkAfter ''
        finance-report ${mcp.serviceConfig.User} ${readerRole}
      '';
      modules.services.postgresql.databases.homelab_finance = {
        additionalRoles.${readerRole} = {
          passwordFile = null;
          grantRoles = [ ];
        };
        databasePermissions.${readerRole} = [ "CONNECT" ];
        schemaPermissions.household_finance.${readerRole} = [ "USAGE" ];
        tablePermissions = {
          "household_finance.money_overview".${readerRole} = [ "SELECT" ];
          "household_finance.export_runs".${readerRole} = [ "SELECT" ];
        };
        customSql.postConfig = [
          ''ALTER ROLE "${readerRole}" SET default_transaction_read_only = on;''
        ];
      };

      # Deliberately no WantedBy/RemainAfterExit: every explicit preparation
      # refreshes the projection from the same effective inputs as MCP.
      systemd.services.finance-report-reader-config = {
        description = "Project only native finance reader inputs (no network)";
        after = [ "sops-install-secrets.service" ];
        requires = [ "sops-install-secrets.service" ];
        environment = mcp.environment;
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
          EnvironmentFile = mcp.serviceConfig.EnvironmentFile;
          # Inputs must not select code/locale loaders for this privileged helper.
          UnsetEnvironment = [
            "LD_PRELOAD"
            "LD_LIBRARY_PATH"
            "LD_AUDIT"
            "LD_DEBUG"
            "LD_DEBUG_OUTPUT"
            "LD_PROFILE"
            "LD_ORIGIN_PATH"
            "GCONV_PATH"
            "LOCPATH"
            "GLIBC_TUNABLES"
            "BASH_ENV"
            "ENV"
            "PYTHONPATH"
            "PYTHONHOME"
          ];
          ExecStart = "${helper} project";
          RuntimeDirectory = "finance-report-reader";
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = true;
          ReadWritePaths = [ readerDir ];
          UMask = "0077";
          TimeoutStartSec = "30s";
          Restart = "no";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          PrivateNetwork = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          CapabilityBoundingSet = [ "CAP_CHOWN" "CAP_DAC_OVERRIDE" "CAP_FOWNER" ];
          InaccessiblePaths = [ "/var/lib" "-/run/postgresql" "-/run/credentials" ];
          StandardOutput = "null";
          StandardError = "journal";
        };
      };

      systemd.services."finance-report-prepare@" = {
        description = "Manually prepare a private %i finance artifact; never send";
        after = [
          "zfs-service-datasets.service"
          "postgresql-provision-databases.service"
          "finance-report-reader-config.service"
        ];
        requires = [
          "zfs-service-datasets.service"
          "postgresql-provision-databases.service"
          "finance-report-reader-config.service"
        ];
        unitConfig = mountGate;
        path = [ pkgs.git ];
        environment = {
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          GIT_SSL_CAINFO = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        };
        serviceConfig = sandbox // {
          Type = "oneshot";
          ExecStart = "${helper} prepare ${app.package}/bin/homelab-finances-report %i";
          StateDirectory = "homelab-mcp/finance-reports";
          StateDirectoryMode = "0700";
          BindPaths = [ reportDir ];
          BindReadOnlyPaths = [ "${dataDir}/finances-ingest" readerDir "/run/postgresql" ];
          ReadWritePaths = [ reportDir ];
          ReadOnlyPaths = [ "${dataDir}/finances-ingest" readerDir ];
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
          TimeoutStartSec = "240s";
          TimeoutStopSec = "60s";
          KillMode = "control-group";
          Restart = "no";
          StandardOutput = "null";
          StandardError = "journal";
        };
      };
    })

    (lib.mkIf cfg.capture.enable {
      # The parent provisions the encrypted value before opening this gate.
      sops.secrets.${transportSecret} = {
        sopsFile = ../secrets.sops.yaml;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      assertions = [
        {
          assertion = config.sops.secrets ? ${transportSecret}
            && config.sops.secrets.${transportSecret}.owner == "root"
            && config.sops.secrets.${transportSecret}.mode == "0400"
            && transportFile != app.environmentFile;
          message = "finance-signal staging capture requires the parent-provisioned root-only transport-only SOPS secret; never the MCP environment.";
        }
        {
          assertion = signal.enable && signal.localAccess.enable
            && builtins.elem mcp.serviceConfig.User signal.localAccess.allowedUsers;
          message = "finance-signal staging capture requires the existing Signal loopback UID guard to permit the MCP identity.";
        }
      ];

      systemd.services.finance-signal-capture-staging = {
        description = "MANUAL ONLY: Ops finance capture, isolated test context";
        after = [ "zfs-service-datasets.service" "podman-signal-api.service" "sops-install-secrets.service" ];
        requires = [ "zfs-service-datasets.service" "podman-signal-api.service" "sops-install-secrets.service" ];
        unitConfig = mountGate // {
          StartLimitIntervalSec = 600;
          StartLimitBurst = 3;
        };
        serviceConfig = sandbox // {
          Type = "simple";
          EnvironmentFile = [ transportFile ];
          ExecStart = "${helper} capture ${app.package}/bin/homelab-finances-signal ${toString signal.port}";
          StateDirectory = "homelab-mcp/finance-signal-staging";
          StateDirectoryMode = "0700";
          BindPaths = [ stagingDir ];
          ReadWritePaths = [ stagingDir ];
          InaccessiblePaths = sandbox.InaccessiblePaths ++ [
            "-/run/finance-report-reader"
            "-/run/postgresql"
          ];
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
          IPAddressDeny = "any";
          IPAddressAllow = [ "127.0.0.1/32" "::1/128" ];
          Restart = "on-failure";
          RestartSec = "30s";
          TimeoutStopSec = "60s";
          KillMode = "control-group";
        };
      };

      systemd.services.finance-signal-staging-status = {
        description = "Read-only, credential-free finance capture status JSON";
        after = [ "zfs-service-datasets.service" ];
        requires = [ "zfs-service-datasets.service" ];
        unitConfig = mountGate;
        serviceConfig = sandbox // {
          Type = "oneshot";
          ExecStart = "${app.package}/bin/homelab-finances-signal status --database ${stagingDir}/context.db";
          BindReadOnlyPaths = [ "-${stagingDir}" ];
          ReadOnlyPaths = [ "-${stagingDir}" ];
          InaccessiblePaths = sandbox.InaccessiblePaths ++ [
            "-/run/finance-report-reader"
            "-/run/postgresql"
          ];
          PrivateNetwork = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          TimeoutStartSec = "15s";
          Restart = "no";
          StandardOutput = "journal";
        };
      };
    })
  ];
}
