{ config, lib, mylib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.modules.services.vscode-agent-host;
  name = "vscode-agent-host";
  ids = mylib.serviceUids.${name};
  workspacePaths = map (workspace: "${cfg.dataDir}/workspaces/${workspace}") cfg.workspaces;
  code = "${cfg.package}/bin/code";
  commonEnvironment = {
    HOME = cfg.dataDir;
    SHELL = "${pkgs.bashInteractive}/bin/bash";
    XDG_CONFIG_HOME = "${cfg.dataDir}/config";
    XDG_DATA_HOME = "${cfg.dataDir}/data";
    XDG_CACHE_HOME = "${cfg.dataDir}/cache";
    TMPDIR = "/run/${name}";
    VSCODE_CLI_DATA_DIR = "${cfg.dataDir}/cli";
    PAGER = "cat";
    NODE_EXTRA_CA_CERTS = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  };
  hardening = {
    User = name;
    Group = name;
    UMask = "0077";
    NoNewPrivileges = true;
    # Empty lists disappear during NixOS unit rendering; empty strings reset.
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectProc = "invisible";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    LockPersonality = true;
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    # Hide other applications' state, not merely their secret files. The
    # dedicated StateDirectory is automatically bound back into this mount.
    TemporaryFileSystem = [ "/var/lib:ro" ];
    InaccessiblePaths = [
      "-/data"
      "-/mnt"
      "-/persist"
      "-/etc/nixos"
      "-/etc/ssh"
      "-/run/secrets"
      "-/run/secrets-for-users"
      "-/run/sops"
      "-/run/docker.sock"
      "-/run/podman"
      "-/run/dbus"
      "-/run/nix/daemon-socket"
      "-/var/backups"
      "-/var/log"
    ];
    StateDirectory = name;
    StateDirectoryMode = "0700";
    RuntimeDirectory = name;
    RuntimeDirectoryMode = "0700";
    RuntimeDirectoryPreserve = true;
    ReadWritePaths = [ cfg.dataDir "/run/${name}" ];
  };
  check = pkgs.writeShellScript "${name}-check" ''
    exec ${pkgs.python3}/bin/python3 ${./healthcheck.py} \
      --executable ${code} --data-dir ${cfg.dataDir} \
      --port ${toString cfg.port} "$@"
  '';
  start = pkgs.writeShellScript "${name}-start" ''
    set -euo pipefail
    ${pkgs.coreutils}/bin/install -d -m 0700 \
      ${lib.escapeShellArgs (workspacePaths ++ [
        "${cfg.dataDir}/cli"
        "${cfg.dataDir}/user-data"
        "${cfg.dataDir}/server"
        "${cfg.dataDir}/config"
        "${cfg.dataDir}/data"
        "${cfg.dataDir}/cache"
        "${cfg.dataDir}/logs"
      ])}
    # Upstream prints ?tkn= in its banner even at --log off. Keep all raw
    # supervisor output private rather than shipping credentials to journald/Loki.
    exec ${code} --disable-telemetry --log warn \
      --cli-data-dir ${cfg.dataDir}/cli \
      agent host --foreground --new-instance \
      --host 127.0.0.1 --port ${toString cfg.port} \
      --connection-token-file "$CREDENTIALS_DIRECTORY/connection-token" \
      --server-data-dir ${cfg.dataDir}/server \
      --user-data-dir ${cfg.dataDir}/user-data \
      >>${cfg.dataDir}/logs/supervisor.log 2>&1
  '';
in
{
  options.modules.services.vscode-agent-host = {
    enable = mkEnableOption "a standalone, native VS Code Agent Host (not vscode-server)";
    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../../../pkgs/vscode-agent-host.nix { };
      defaultText = lib.literalExpression "pkgs.vscode-agent-host";
      description = "Pinned CLI and runtime; startup refuses an unsupported command.";
    };
    dataDir = mkOption {
      type = types.str;
      readOnly = true;
      default = "/var/lib/${name}";
      description = "Private persistent home, sessions, credentials and workspace root.";
    };
    user = mkOption {
      type = types.str;
      readOnly = true;
      default = name;
      description = "Dedicated unprivileged service identity.";
    };
    group = mkOption {
      type = types.str;
      readOnly = true;
      default = name;
      description = "Dedicated private service group.";
    };
    port = mkOption {
      type = types.port;
      default = 17890;
      description = "IPv4 loopback-only listener; forward over operator SSH.";
    };
    connectionTokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Absolute runtime path to a SOPS-managed connection token, never store content.";
    };
    startAtBoot = mkEnableOption "boot startup after operator runtime acceptance";
    runtimeAccepted = mkEnableOption "the operator-recorded login/reconnection/lifecycle acceptance gate";
    workspaces = mkOption {
      type = types.listOf (types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*");
      default = [ "scratch" ];
      description = ''
        Explicit workspace directories under dataDir/workspaces. Every session
        shares this identity and trust domain; these are not per-project sandboxes.
      '';
    };
    tools = mkOption {
      type = types.listOf types.package;
      default = [ pkgs.bashInteractive pkgs.coreutils pkgs.git pkgs.ripgrep pkgs.python3 ];
      description = "Host-native coding/test tools, with no sudo or container runtime.";
    };
    memoryMax = mkOption {
      type = types.str;
      default = "4G";
      description = "Systemd memory limit for the entire agent process tree.";
    };
    cpuQuota = mkOption {
      type = types.str;
      default = "200%";
      description = "Systemd CPU quota for the agent process tree.";
    };
    tasksMax = mkOption {
      type = types.ints.positive;
      default = 256;
      description = "Maximum processes/threads in the agent service.";
    };
    backup = mkOption {
      type = types.nullOr mylib.types.backupSubmodule;
      default = null;
      description = "Unified backup discovery; include all private state and uncommitted work.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.connectionTokenFile != null
          && lib.hasPrefix "/" cfg.connectionTokenFile
          && !(lib.hasPrefix "/nix/store/" cfg.connectionTokenFile);
        message = "vscode-agent-host requires a runtime SOPS connectionTokenFile outside the Nix store.";
      }
      {
        assertion = !cfg.startAtBoot || cfg.runtimeAccepted;
        message = "vscode-agent-host boot startup requires explicit operator runtimeAccepted.";
      }
      {
        assertion = cfg.workspaces != [ ] && lib.unique cfg.workspaces == cfg.workspaces;
        message = "vscode-agent-host requires a nonempty, unique workspace list.";
      }
      {
        assertion = config.users.users.${name}.extraGroups == [ ];
        message = "vscode-agent-host must not join other service, wheel or container groups.";
      }
    ];

    users.users.${name} = {
      uid = ids.uid;
      isSystemUser = true;
      group = name;
      home = cfg.dataDir;
      createHome = false;
      extraGroups = [ ];
      description = "Standalone VS Code Agent Host";
    };
    users.groups.${name}.gid = ids.gid;

    systemd.services.${name} = {
      description = "Standalone VS Code Agent Host (authenticated loopback)";
      wantedBy = lib.optional cfg.startAtBoot "multi-user.target";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig = (mylib.systemd-restart.mkStartLimit {
        restartSec = 10;
        failureBudget = 150; # 120s startup plus at most 30s process-tree cleanup.
        burst = 3;
      }) // { RequiresMountsFor = [ cfg.dataDir ]; };
      environment = commonEnvironment;
      path = cfg.tools;
      serviceConfig = hardening // {
        Type = "exec";
        WorkingDirectory = cfg.dataDir;
        LoadCredential = [ "connection-token:${toString cfg.connectionTokenFile}" ];
        ExecStartPre = "${pkgs.python3}/bin/python3 ${./preflight.py} --executable ${code} --version ${cfg.package.version} --token-file %d/connection-token";
        ExecStart = start;
        ExecStartPost = "${check} --attempts 10 --timeout 8";
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStartSec = "120s";
        TimeoutStopSec = "30s";
        KillMode = "control-group";
        MemoryMax = cfg.memoryMax;
        CPUQuota = cfg.cpuQuota;
        TasksMax = cfg.tasksMax;
        LimitCORE = 0;
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    systemd.services."${name}-healthcheck" = {
      description = "Authenticated Agent Host protocol readiness (no inference)";
      after = [ "${name}.service" ];
      environment = commonEnvironment;
      path = [ pkgs.coreutils ];
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = check;
        TimeoutStartSec = "20s";
        MemoryMax = "256M";
        TasksMax = 64;
      };
    };
    systemd.timers."${name}-healthcheck" = {
      description = "Probe the standalone Agent Host independently of editor clients";
      wantedBy = lib.optional cfg.startAtBoot "timers.target";
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "2m";
        AccuracySec = "15s";
      };
    };

    services.logrotate.settings.${name} = {
      files = [
        "${cfg.dataDir}/logs/supervisor.log"
        "${cfg.dataDir}/.vscode-server/cli/agent-host-stable.log"
      ];
      frequency = "daily";
      maxsize = "10M";
      rotate = 7;
      compress = true;
      delaycompress = true;
      missingok = true;
      notifempty = true;
      copytruncate = true;
      su = "${name} ${name}";
    };
  };
}
