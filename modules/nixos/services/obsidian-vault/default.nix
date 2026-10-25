# Obsidian vault on Forge: official headless Sync client plus a vault MCP server.
#
# The Sync client is pkgs.unstable.obsidian-headless (unfree, absent from
# nixos-25.11). It runs `ob sync --continuous` as an unprivileged user.
# Login and `ob sync-setup` are one-time and interactive; until the auth
# token file exists the unit is skipped (ConditionFileNotEmpty), not failed.
#
# The MCP server is pkgs.obsidian-web-mcp (jimprosser/obsidian-web-mcp).
# It binds loopback and can read and write only the vault directory. The
# Obsidian auth token lives in a 0700 config directory the MCP user cannot
# enter. Public exposure is a Caddy vhost with an optional Cloudflare tunnel
# and a static bearer from sops; it stays off until mcp.tokenProvisioned.
{ config, lib, pkgs, mylib, ... }:

let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption types;

  cfg = config.modules.services."obsidian-vault";
  serviceIds = mylib.serviceUids.obsidian-sync;
  mcpIds = mylib.serviceUids.obsidian-vault-mcp;
  vaultGroupIds = mylib.serviceUids.obsidian-vault;

  storageHelpers = mylib.storageHelpers pkgs;
  sharedTypes = mylib.types;

  serviceName = "obsidian-vault";
  syncUnit = "obsidian-sync";
  mcpUnit = "obsidian-vault-mcp";
  hintUnit = "obsidian-sync-await-login";

  syncUser = "obsidian-sync";
  mcpUser = "obsidian-vault-mcp";
  vaultGroup = "obsidian-vault";

  stateDir = cfg.stateDir;
  configHome = "${stateDir}/.config";
  authToken = "${configHome}/obsidian-headless/auth_token";
  vaultDir = cfg.vaultDir;
  mcpStateDir = "${stateDir}/mcp-state";
  auditLog = "${mcpStateDir}/audit.jsonl";

  storageCfg = config.modules.storage;
  datasetPath =
    if (storageCfg.datasets or { }) ? parentDataset
    then "${storageCfg.datasets.parentDataset}/${serviceName}"
    else null;

  replicationConfig = storageHelpers.mkReplicationConfig {
    inherit config;
    datasetPath = if datasetPath == null then "" else datasetPath;
  };
  allowEmptyBootstrap = storageHelpers.allowEmptyBootstrapFor {
    inherit config;
    datasetName = serviceName;
  };

  ob = lib.getExe cfg.package;
  vaultMcp = lib.getExe cfg.mcpPackage;

  # install(1) as root, before the service drops privileges. The dataset
  # mount has to already be in place (After=zfs-service-datasets) or these
  # directories land on the impermanence root and disappear at next boot.
  ensureDirs = ''
    ${pkgs.coreutils}/bin/install -d -o ${syncUser} -g ${vaultGroup} -m 0750 ${stateDir}
    ${pkgs.coreutils}/bin/install -d -o ${syncUser} -g ${syncUser} -m 0700 ${configHome}
    ${pkgs.coreutils}/bin/install -d -o ${syncUser} -g ${vaultGroup} -m 2770 ${vaultDir}
    ${pkgs.coreutils}/bin/install -d -o ${mcpUser} -g ${mcpUser} -m 0700 ${mcpStateDir}
  '';

  hardening = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    SystemCallArchitectures = "native";
    # Group-writable creates, so the setgid vault directory (2770) hands
    # the MCP user write access through the shared group. A program that
    # chmod's after create can still defeat this; see the host module notes.
    UMask = "0007";
  };

  setupCommand = "sudo -u ${syncUser} -H ${ob} sync-setup --vault ${lib.escapeShellArg cfg.remoteVaultName} --path ${vaultDir} --device-name ${lib.escapeShellArg cfg.deviceName}";

  # Printed only while the auth token is absent. The sync unit itself
  # never starts in that state (ConditionFileNotEmpty), so this text
  # does not belong in its journal.
  loginHint = ''
    Obsidian Sync has no auth token yet (${authToken}).
    obsidian-sync.service stays inactive until that file exists.
    On forge, once, as the service user (its home is ${stateDir}):
      sudo -u ${syncUser} -H ${ob} login
      ${setupCommand}
    sync-setup prompts for the end-to-end password and stores it under ${configHome}. It is not written to git.
    Then: sudo systemctl start ${syncUnit}.service
  '';

  # Printed when the token exists and ob is about to run. Covers the
  # logged-in but not-yet-linked case, where ob exits on its own.
  syncPreamble = ''
    Obsidian Sync client starting for ${vaultDir}.
    If it exits with "No sync configuration found", this device is not linked yet. Run once:
      ${setupCommand}
  '';
in
{
  options.modules.services."obsidian-vault" = {
    enable = mkEnableOption "Obsidian headless Sync and the vault MCP server";

    package = mkOption {
      type = types.package;
      # Read only when enable is true, so a disabled host does not pull this
      # unfree package into its closure. nixos-25.11 does not ship it.
      default = pkgs.unstable.obsidian-headless;
      defaultText = "pkgs.unstable.obsidian-headless";
      description = "Official Obsidian headless Sync client (the ob command).";
    };

    mcpPackage = mkOption {
      type = types.package;
      default = pkgs.obsidian-web-mcp;
      defaultText = "pkgs.obsidian-web-mcp";
      description = "obsidian-web-mcp package (vault-mcp).";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/obsidian-sync";
      description = ''
        Persistent root for the Sync client. Must be a ZFS dataset mount on
        an impermanence host. The auth token is .config/obsidian-headless/auth_token
        under this directory, mode 0700, and is not readable by the MCP user.
      '';
    };

    vaultDir = mkOption {
      type = types.path;
      default = "/var/lib/obsidian-sync/vault";
      description = "Local vault directory. The only path the MCP user can write.";
    };

    remoteVaultName = mkOption {
      type = types.str;
      default = "Ryan's Vault";
      description = ''
        Remote vault name printed in the one-time sync-setup hint.
        Not sent by the service; ob sync-setup is run by hand.
      '';
    };

    deviceName = mkOption {
      type = types.str;
      default = "forge";
      description = "Device name passed to the one-time ob sync-setup hint.";
    };

    port = mkOption {
      type = types.port;
      default = 8420;
      description = "Loopback port for vault-mcp.";
    };

    hostName = mkOption {
      type = types.str;
      default = "obsidian.${config.networking.domain}";
      defaultText = "obsidian.\${networking.domain}";
      description = ''
        Public hostname for the MCP vhost. The name "vault" under this
        domain is Luna's 1Password Connect server, so this service uses
        obsidian instead.
      '';
    };

    mcp = {
      expose = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Publish the MCP server through Caddy. Requires mcp.tokenProvisioned.
          Combining enable and expose without a token fails the build.
        '';
      };

      tokenProvisioned = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Set true only after secrets.sops.yaml contains obsidian-vault/mcp_token.
          Declares that sops secret and starts vault-mcp. While false, the
          secret attr is absent so evaluation does not require ciphertext
          that has not been added yet.
        '';
      };

      tunnel = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "forge";
        description = ''
          Cloudflare tunnel name, matching modules.services.cloudflared.tunnels.
          null keeps the vhost off the tunnel.
        '';
      };
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration discovered by modules.services.backup.";
    };

    preseed = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "automatic restore before the Sync client starts";

          repositoryUrl = mkOption {
            type = types.str;
            default = "";
            description = "Restic repository URL for preseed restore.";
          };

          passwordFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Path to the Restic repository password.";
          };

          restoreMethods = mkOption {
            type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
            default = [ "syncoid" "local" ];
            description = "Ordered restore methods. Restic is a manual DR step, not the default.";
          };
        };
      };
      default = { };
      description = "Preseed/DR restore configuration.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.mcp.tokenProvisioned || !cfg.mcp.expose;
          message = ''
            modules.services.obsidian-vault: mcp.expose requires mcp.tokenProvisioned.
            Add a one-line obsidian-vault/mcp_token value to hosts/forge/secrets.sops.yaml
            (sops, no plaintext in git), set mcp.tokenProvisioned = true, then rebuild.
            To sync before publishing, set mcp.expose = false.
          '';
        }
        {
          assertion = datasetPath != null;
          message = "modules.services.obsidian-vault requires modules.storage.datasets.parentDataset.";
        }
      ];

      environment.systemPackages = [ cfg.package ];

      users.users.${syncUser} = {
        isSystemUser = true;
        uid = serviceIds.uid;
        group = syncUser;
        extraGroups = [ vaultGroup ];
        home = stateDir;
        createHome = false;
        description = "Obsidian headless Sync client";
      };

      users.users.${mcpUser} = {
        isSystemUser = true;
        uid = mcpIds.uid;
        group = mcpUser;
        extraGroups = [ vaultGroup ];
        home = mcpStateDir;
        createHome = false;
        description = "Obsidian vault MCP server";
      };

      users.groups.${syncUser}.gid = serviceIds.gid;
      users.groups.${mcpUser}.gid = mcpIds.gid;
      users.groups.${vaultGroup}.gid = vaultGroupIds.gid;

      systemd.services.${syncUnit} = {
        description = "Obsidian headless Sync client";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "network-online.target"
          "zfs-service-datasets.service"
        ] ++ lib.optional (cfg.preseed.enable && allowEmptyBootstrap) "preseed-${serviceName}.service";
        requires = lib.optional (cfg.preseed.enable && !allowEmptyBootstrap) "preseed-${serviceName}.service";
        after = [
          "network-online.target"
          "zfs-mount.service"
          "zfs-service-datasets.service"
        ] ++ lib.optional cfg.preseed.enable "preseed-${serviceName}.service";

        # Missing or empty token: skip the unit. That is inactive, not failed,
        # so it does not page SystemdUnitFailed and does not restart.
        unitConfig.ConditionFileNotEmpty = authToken;

        environment = {
          HOME = stateDir;
          XDG_CONFIG_HOME = configHome;
        };

        serviceConfig = hardening // {
          Type = "simple";
          # Type=simple, not the `script` shorthand (that forces oneshot).
          # The wrapper execs ob, so the main process is the Sync client.
          # Not-linked: ob exits, Restart=on-failure, and the start limit
          # marks the unit failed (SystemdUnitFailed). Not-logged-in never
          # reaches this unit.
          ExecStart = pkgs.writeShellScript "obsidian-sync-run" ''
            echo ${lib.escapeShellArg syncPreamble}
            exec ${ob} sync --continuous --path ${lib.escapeShellArg vaultDir}
          '';
          User = syncUser;
          Group = syncUser;
          SupplementaryGroups = [ vaultGroup ];
          WorkingDirectory = stateDir;
          Restart = "on-failure";
          RestartSec = "30s";
          ExecStartPre = "+${pkgs.writeShellScript "obsidian-sync-ensure-dirs" ensureDirs}";
          ReadWritePaths = [ stateDir ];
        };
      };

      # Once per boot while logged out. ExecStart rather than `script`:
      # the NixOS script shorthand is a RemainAfterExit oneshot, which the
      # reexec guard rejects when restartTriggers is empty.
      systemd.services.${hintUnit} = {
        description = "Print Obsidian Sync login steps while the client is logged out";
        wantedBy = [ "multi-user.target" ];
        after = [ "zfs-service-datasets.service" ];
        unitConfig.ConditionPathExists = "!${authToken}";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = false;
          ExecStart = pkgs.writeShellScript "obsidian-sync-await-login" ''
            echo ${lib.escapeShellArg loginHint}
          '';
        };
      };
    }

    (mkIf cfg.mcp.tokenProvisioned {
      sops.secrets."obsidian-vault/mcp_token" = {
        mode = "0400";
        owner = "root";
        group = "root";
        restartUnits = [ "${mcpUnit}.service" ];
      };

      sops.templates."obsidian-vault-mcp-env" = {
        content = ''
          VAULT_MCP_TOKEN=${lib.removeSuffix "\n" config.sops.placeholder."obsidian-vault/mcp_token"}
        '';
        mode = "0400";
        owner = "root";
        group = "root";
        restartUnits = [ "${mcpUnit}.service" ];
      };

      systemd.services.${mcpUnit} = {
        description = "Obsidian vault MCP server";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" "zfs-service-datasets.service" ];
        after = [
          "network-online.target"
          "zfs-mount.service"
          "zfs-service-datasets.service"
          "${syncUnit}.service"
        ];

        environment = {
          HOME = mcpStateDir;
          VAULT_PATH = vaultDir;
          VAULT_MCP_HOST = "127.0.0.1";
          VAULT_MCP_PORT = toString cfg.port;
          VAULT_MCP_PATH = "/";
          VAULT_MCP_ALLOWED_HOSTS = cfg.hostName;
          VAULT_MCP_PUBLIC_URL = "https://${cfg.hostName}";
          VAULT_MCP_FORWARDED_ALLOW_IPS = "127.0.0.1";
          VAULT_AUDIT_LOG_PATH = auditLog;
          OAUTH_CLIENTS_PATH = "${mcpStateDir}/oauth_clients.json";
        };

        path = [ pkgs.ripgrep ];

        serviceConfig = hardening // {
          Type = "simple";
          ExecStart = vaultMcp;
          User = mcpUser;
          Group = mcpUser;
          SupplementaryGroups = [ vaultGroup ];
          WorkingDirectory = mcpStateDir;
          EnvironmentFile = config.sops.templates."obsidian-vault-mcp-env".path;
          Restart = "on-failure";
          RestartSec = "5s";
          ExecStartPre = "+${pkgs.writeShellScript "obsidian-vault-mcp-ensure-dirs" ensureDirs}";
          ReadWritePaths = [ vaultDir mcpStateDir ];
          # The leading '-' ignores a config dir that does not exist yet.
          # Mode 0700 on that dir is what actually keeps the auth token out
          # of the MCP user's reach once `ob login` creates it.
          InaccessiblePaths = [ "-${configHome}" ];
        };
      };
    })

    (mkIf (cfg.mcp.expose && cfg.mcp.tokenProvisioned) {
      modules.services.caddy.virtualHosts.${serviceName} = {
        enable = true;
        hostName = cfg.hostName;
        backend = {
          host = "127.0.0.1";
          port = cfg.port;
        };
        # The process authenticates the bearer itself. A Pocket ID guard in
        # front would loop the same way it would for homelab-mcp.
        cloudflare =
          if cfg.mcp.tunnel == null then null
          else {
            enable = true;
            tunnel = cfg.mcp.tunnel;
          };
      };
    })

    (mkIf (cfg.preseed.enable && datasetPath != null) (
      storageHelpers.mkPreseedService {
        inherit serviceName allowEmptyBootstrap;
        dataset = datasetPath;
        mountpoint = stateDir;
        mainServiceUnit = "${syncUnit}.service";
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "128K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticPaths = [ stateDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        owner = syncUser;
        group = vaultGroup;
      }
    ))
  ]);
}
