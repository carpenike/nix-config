{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf mkMerge mkDefault mkForce types;

  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.home-assistant;
  storageCfg = config.modules.storage;
  notificationsCfg = config.modules.notifications;

  hasCentralizedNotifications = notificationsCfg.enable or false;
  serviceName = "home-assistant";
  serviceUnit = "${serviceName}.service";
  defaultPort = 8123;
  datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";

  # Recursively walk dataset tree to find the closest replication config.
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = (config.modules.backup.sanoid.datasets or { });
        replicationInfo = (sanoidDatasets.${dsPath} or { }).replication or null;
        parentPath =
          if lib.elem "/" (lib.stringToCharacters dsPath) then
            lib.removeSuffix ("/" + lib.last (lib.splitString "/" dsPath)) dsPath
          else
            "";
      in
      if replicationInfo != null then
        { sourcePath = dsPath; replication = replicationInfo; }
      else
        findReplication parentPath;

  foundReplication =
    if config.modules.backup.sanoid.enable or false then
      findReplication datasetPath
    else
      null;

  replicationConfig =
    if foundReplication == null then null else
      let
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        targetDataset =
          if datasetSuffix == "" then
            foundReplication.replication.targetDataset
          else
            "${foundReplication.replication.targetDataset}/${datasetSuffix}";
        sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
        sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
        sendOptions = foundReplication.replication.sendOptions or "w";
        recvOptions = foundReplication.replication.recvOptions or "u";
      };
in
{
  options.modules.services.home-assistant = {
    enable = mkEnableOption "Home Assistant service wrapper (native NixOS module)";

    package = mkOption {
      type = types.package;
      default = pkgs.home-assistant.overrideAttrs (old: old // { doInstallCheck = false; });
      description = "Home Assistant package to deploy.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/home-assistant";
      description = "ZFS-backed data directory (passed through to services.home-assistant.configDir).";
    };

    port = mkOption {
      type = types.port;
      default = defaultPort;
      description = "Internal HTTP port that Caddy reverse proxy will target. Ensure this matches Home Assistant's configured port.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional CLI arguments passed to the Home Assistant service.";
    };

    extraComponents = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Optional Home Assistant components to include via services.home-assistant.extraComponents.";
    };

    extraPackages = mkOption {
      type = types.functionTo (types.listOf types.package);
      default = _: [ ];
      defaultText = lib.literalExpression "python3Packages: [ ]";
      description = "Function returning extra Python packages for Home Assistant (forwarded to services.home-assistant.extraPackages).";
    };

    extraLibs = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Additional shared libraries exposed to Home Assistant via LD_LIBRARY_PATH.";
    };

    environmentFiles = mkOption {
      type = types.listOf types.path;
      default = [ ];
      description = "Environment files passed to the Home Assistant service (EnvironmentFile=) for !env_var secrets.";
    };

    declarativeConfig = mkOption {
      type = types.nullOr (types.attrsOf types.anything);
      default = null;
      description = ''Optional declarative configuration (maps to services.home-assistant.config). Leave null to manage configuration via the UI.'';
    };

    configWritable = mkOption {
      type = types.bool;
      default = false;
      description = "Whether Home Assistant's configuration.yaml should remain writable by the UI (services.home-assistant.configWritable).";
    };

    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for serving Home Assistant through Caddy.";
    };

    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = serviceUnit;
        labels = {
          service = serviceName;
          service_type = "automation";
        };
      };
      description = "Log shipping configuration (journald by default).";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = mkIf cfg.enable {
        enable = mkDefault true;
        repository = mkDefault "nas-primary";
        frequency = mkDefault "daily";
        tags = mkDefault [ "home-automation" serviceName "config" ];
        useSnapshots = mkDefault true;
        zfsDataset = mkDefault datasetPath;
        excludePatterns = mkDefault [ "**/deps/**" "**/.cache/**" ];
      };
      description = "Backup configuration for Home Assistant data.";
    };

    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = { onFailure = [ "system-alerts" ]; };
        customMessages = { failure = "Home Assistant failed on ${config.networking.hostName}"; };
      };
      description = "Notification routing for Home Assistant failures.";
    };

    preseed = {
      enable = mkEnableOption "automatic dataset restore before Home Assistant starts";
      repositoryUrl = mkOption {
        type = types.str;
        description = "Restic repository URL used for preseed restores.";
      };
      passwordFile = mkOption {
        type = types.path;
        description = "Path to Restic password file.";
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional Restic environment file.";
      };
      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Restore method order for preseeding the dataset.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.backup == null || !cfg.backup.enable || cfg.backup.repository != null;
          message = "Home Assistant backup.enable requires backup.repository to be set.";
        }
        {
          assertion = cfg.preseed.enable -> (cfg.preseed.repositoryUrl or "") != "";
          message = "Home Assistant preseed requires a Restic repository URL.";
        }
      ];

      services.home-assistant = {
        enable = true;
        package = cfg.package;
        configDir = cfg.dataDir;
        configWritable = cfg.configWritable;
        config = cfg.declarativeConfig;
        extraArgs = cfg.extraArgs;
        extraComponents = cfg.extraComponents;
        extraPackages = cfg.extraPackages;
      };

      # Reverse proxy registration with Caddy
      modules.services.caddy.virtualHosts.${serviceName} = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = cfg.port;
        };
        auth = cfg.reverseProxy.auth or null;
        authelia = cfg.reverseProxy.authelia or null;
        security = cfg.reverseProxy.security or { };
        reverseProxyBlock = ''
          header_up -Connection
          header_up Connection "Upgrade"
          header_up -X-Forwarded-For
          header_up -X-Forwarded-Proto
          header_up -X-Forwarded-Host
          header_up -X-Forwarded-Port
          header_up -Forwarded
          ${cfg.reverseProxy.extraConfig or ""}
        '';
      };

      modules.services.authelia.accessControl.declarativelyProtectedServices.${serviceName} = mkIf (
        config.modules.services.authelia.enable &&
        cfg.reverseProxy != null &&
        cfg.reverseProxy.enable &&
        cfg.reverseProxy.authelia != null &&
        cfg.reverseProxy.authelia.enable
      ) (
        let
          authCfg = cfg.reverseProxy.authelia;
        in {
          domain = cfg.reverseProxy.hostName;
          policy = authCfg.policy;
          subject = map (group: "group:${group}") (authCfg.allowedGroups or [ ]);
          bypassResources =
            (map (path: "^${lib.escapeRegex path}/.*$") (authCfg.bypassPaths or [ ])) ++
            (authCfg.bypassResources or [ ]);
        }
      );

      # ZFS dataset management for Home Assistant state
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = cfg.dataDir;
        recordsize = "16K";
        compression = "zstd";
        properties = { "com.sun:auto-snapshot" = "true"; };
        owner = "hass";
        group = "hass";
        mode = "0750";
      };

      # Systemd unit coordination
      systemd.services.${serviceName} = {
        unitConfig = {
          RequiresMountsFor = [ cfg.dataDir ];
        } // (mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          OnFailure = [ "notify@home-assistant-failure:%n.service" ];
        });
        wants = mkIf cfg.preseed.enable [ "preseed-${serviceName}.service" ];
        after = mkIf cfg.preseed.enable [ "preseed-${serviceName}.service" ];
        environment = mkIf (cfg.extraLibs != [ ]) {
          LD_LIBRARY_PATH = lib.makeLibraryPath cfg.extraLibs;
        };
        serviceConfig =
          ({
            ReadWritePaths = mkForce [ cfg.dataDir ];
            WorkingDirectory = mkForce cfg.dataDir;
          }
          // (mkIf (cfg.environmentFiles != [ ]) {
            EnvironmentFile = cfg.environmentFiles;
          }));
        };

      # Ensure native Home Assistant account follows repo-wide conventions
      users.users.hass = {
        home = mkForce "/var/empty";
        createHome = mkForce false;
        isSystemUser = mkForce true;
        group = mkDefault "hass";
      };

      users.groups.hass = { };

      modules.notifications.templates = mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "home-assistant-failure" = {
          enable = mkDefault true;
          priority = mkDefault "high";
          title = mkDefault ''<b><font color="red">✗ Service Failed: Home Assistant</font></b>'';
          body = mkDefault ''
            <b>Host:</b> ''${config.networking.hostName}
            <b>Service:</b> <code>''${serviceUnit}</code>
            <b>Action:</b> ssh ''${config.networking.hostName} 'journalctl -u ''${serviceUnit} -n 200' && sudo systemctl restart ''${serviceUnit}
          '';
        };
      };
    })

    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = serviceUnit;
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = "hass";
        group = "hass";
      }
    ))
  ];
}
