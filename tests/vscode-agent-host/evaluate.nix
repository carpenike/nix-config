{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  forge = inputs.self.nixosConfigurations.forge;
  base = (forge.extendModules {
    modules = [{
      modules.services.vscode-agent-host = {
        enable = lib.mkForce false;
        startAtBoot = lib.mkForce false;
        runtimeAccepted = lib.mkForce false;
      };
    }];
  }).config;
  manual = (forge.extendModules {
    modules = [{
      modules.services.vscode-agent-host = {
        enable = lib.mkForce true;
        startAtBoot = lib.mkForce false;
        runtimeAccepted = lib.mkForce false;
      };
    }];
  }).config;
  accepted = (forge.extendModules {
    modules = [{
      modules.services.vscode-agent-host = {
        enable = lib.mkForce true;
        startAtBoot = lib.mkForce true;
        runtimeAccepted = lib.mkForce true;
      };
    }];
  }).config;
  invalid = overrides: (forge.extendModules {
    modules = [{
      modules.services.vscode-agent-host = {
        enable = lib.mkForce true;
        runtimeAccepted = lib.mkForce false;
      } // overrides;
    }];
  }).config;
  rejects = c: lib.any
    (a: lib.hasPrefix "vscode-agent-host" a.message && !a.assertion)
    c.assertions;
  cfg = accepted.modules.services.vscode-agent-host;
  service = accepted.systemd.services.vscode-agent-host;
  sc = service.serviceConfig;
  dataset = accepted.modules.storage.datasets.services.vscode-agent-host;
  checks = {
    disabled-mode-is-inert = !base.modules.services.vscode-agent-host.enable
      && !(base.systemd.services ? vscode-agent-host)
      && !(base.users.users ? vscode-agent-host)
      && !(base.sops.secrets ? "vscode-agent-host/connection-token")
      && !(base.modules.storage.datasets.services ? vscode-agent-host);
    manual-acceptance-is-not-boot-activation =
      manual.systemd.services.vscode-agent-host.wantedBy == [ ]
      && manual.systemd.timers.vscode-agent-host-healthcheck.wantedBy == [ ];
    production-has-two-explicit-gates =
      service.wantedBy == [ "multi-user.target" ]
      && accepted.systemd.timers.vscode-agent-host-healthcheck.wantedBy == [ "timers.target" ]
      && rejects (invalid { startAtBoot = lib.mkForce true; });
    missing-token-is-rejected = rejects (invalid {
      connectionTokenFile = lib.mkForce null;
    });
    store-token-is-rejected = rejects (invalid {
      connectionTokenFile = lib.mkForce "/nix/store/not-a-secret";
    });
    empty-workspaces-are-rejected = rejects (invalid {
      workspaces = lib.mkForce [ ];
    });
    identity-is-private-and-stable =
      accepted.users.users.vscode-agent-host.uid == 1068
      && accepted.users.groups.vscode-agent-host.gid == 1068
      && accepted.users.users.vscode-agent-host.extraGroups == [ ]
      && sc.User == "vscode-agent-host"
      && sc.Group == "vscode-agent-host"
      && sc.UMask == "0077"
      && sc.StateDirectoryMode == "0700"
      && sc.RuntimeDirectoryMode == "0700";
    runtime-is-pinned = cfg.package.version == "1.139.1"
      && cfg.package.commit == "04c0d99f4fb0d8afe6ce4f0c58e31e183ac3e4b1";
    secrets-are-runtime-credentials =
      sc.LoadCredential == [ "connection-token:/run/secrets/vscode-agent-host/connection-token" ]
      && !(service.environment ? GITHUB_TOKEN)
      && !(service.environment ? ANTHROPIC_API_KEY)
      && !(service.environment ? ACTUAL_PASSWORD);
    host-state-and-privileges-are-hidden =
      sc.NoNewPrivileges && sc.ProtectHome
      && sc.ProtectSystem == "strict"
      && sc.CapabilityBoundingSet == ""
      && lib.hasInfix "CapabilityBoundingSet=\n" accepted.systemd.units."vscode-agent-host.service".text
      && lib.hasInfix "AmbientCapabilities=\n" accepted.systemd.units."vscode-agent-host.service".text
      && sc.TemporaryFileSystem == [ "/var/lib:ro" ]
      && lib.all (p: builtins.elem p sc.InaccessiblePaths)
        [ "-/data" "-/mnt" "-/persist" "-/run/secrets" "-/run/docker.sock" "-/run/nix/daemon-socket" ];
    no-new-firewall-or-proxy-exposure =
      accepted.networking.firewall.allowedTCPPorts == base.networking.firewall.allowedTCPPorts
      && accepted.networking.firewall.allowedUDPPorts == base.networking.firewall.allowedUDPPorts
      && !(accepted.modules.services.caddy.virtualHosts ? vscode-agent-host);
    resource-and-restart-bounds =
      sc.MemoryMax == "4G" && sc.CPUQuota == "200%" && sc.TasksMax == 256
      && service.unitConfig.StartLimitBurst == 3
      && service.unitConfig.StartLimitIntervalSec > 2 * (120 + 30 + 10)
      && sc.KillMode == "control-group"
      && sc.TimeoutStartSec == "120s";
    storage-startup-order =
      builtins.elem "zfs-service-datasets.service" service.requires
      && builtins.elem "zfs-service-datasets.service" service.after
      && service.unitConfig.RequiresMountsFor == [ cfg.dataDir ]
      && service.unitConfig.AssertPathIsMountPoint == [ cfg.dataDir ];
    private-state-and-workspaces-are-backed-up =
      dataset.mountpoint == cfg.dataDir && dataset.mode == "0700"
      && dataset.owner == cfg.user && dataset.properties.quota == "20G"
      && cfg.backup.enable && cfg.backup.useSnapshots
      && cfg.backup.zfsDataset == "tank/services/vscode-agent-host"
      && accepted.modules.backup.sanoid.datasets."tank/services/vscode-agent-host".replication.targetDataset
      == "backup/forge/zfs-recv/vscode-agent-host"
      && accepted.modules.services.backup._internal.allJobs."service-vscode-agent-host".enable
      && accepted.modules.services.backup._internal.allJobs."vscode-agent-host-offsite".repository == "r2-offsite";
    backups-preserve-private-permissions =
      accepted.systemd.services."restic-backup-service-vscode-agent-host".serviceConfig.AmbientCapabilities == [ "CAP_DAC_READ_SEARCH" ]
      && accepted.systemd.services."restic-backup-vscode-agent-host-offsite".serviceConfig.AmbientCapabilities == [ "CAP_DAC_READ_SEARCH" ];
    independent-health-and-alerts =
      accepted.systemd.services.vscode-agent-host-healthcheck.serviceConfig.TimeoutStartSec == "20s"
      && accepted.modules.alerting.rules ? vscode-agent-host-transport-failed
      && accepted.modules.alerting.rules ? vscode-agent-host-healthcheck-timer-down
      && accepted.modules.alerting.rules.vscode-agent-host-transport-failed.for == "30s";
    legacy-editor-server-is-unchanged =
      base.services.vscode-server.enable && accepted.services.vscode-server.enable;
  };
  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg (failed == [ ])
  "Agent Host foundation regressions: ${lib.concatStringsSep ", " failed}";
checks
