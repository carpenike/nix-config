{ config, lib, mylib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf mkMerge mkDefault mkForce mkBefore types;

  # Service UID/GID from centralized registry
  serviceIds = mylib.serviceUids.home-assistant;

  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;
  sharedTypes = mylib.types;

  cfg = config.modules.services.home-assistant;
  storageCfg = config.modules.storage;
  notificationsCfg = config.modules.notifications;

  hasCentralizedNotifications = notificationsCfg.enable or false;
  serviceName = "home-assistant";
  serviceUnit = "${serviceName}.service";
  defaultPort = 8123;
  datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
  allowEmptyBootstrap = storageHelpers.allowEmptyBootstrapFor {
    inherit config;
    datasetName = serviceName;
  };

  # dataDir doubles as an operator-managed git working tree, so files Home
  # Assistant writes itself can be re-created under a human's ownership by a
  # checkout and silently strip hass's write access. Repair only the paths HA
  # actually writes; everything else (.git, packages/, dashboards/, scripts/)
  # is read-only for hass by design and is deliberately left alone.
  absWritableFiles = map (p: "${cfg.dataDir}/${p}") cfg.runtimeWritableFiles;
  absWritableDirs = map (p: "${cfg.dataDir}/${p}") cfg.runtimeWritableDirs;

  # Runs as root via the "+" ExecStartPre prefix. This deliberately duplicates
  # the tmpfiles rules below: tmpfiles only fires on activation, but a git
  # checkout between two rebuilds is exactly how the ownership drifts, so the
  # repair has to run on every start for the service to be unbreakable.
  ownershipRepair = pkgs.writeShellScript "${serviceName}-ownership-repair" ''
    set -euo pipefail

    for path in ${lib.escapeShellArgs absWritableFiles}; do
      [ -e "$path" ] || continue
      ${pkgs.coreutils}/bin/chown hass:hass "$path"
      # A checkout can also land a read-only mode; owner-write is what matters.
      ${pkgs.coreutils}/bin/chmod u+w "$path"
    done

    for path in ${lib.escapeShellArgs absWritableDirs}; do
      [ -d "$path" ] || continue
      # Modes are left alone so 0600 credentials under .storage stay restrictive.
      ${pkgs.coreutils}/bin/chown -R hass:hass "$path"
    done
  '';
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

    runtimeWritableFiles = mkOption {
      type = types.listOf types.str;
      default = [ ".HA_VERSION" "automations.yaml" "scenes.yaml" "scripts.yaml" ];
      description = ''
        Files under dataDir that Home Assistant writes at runtime, relative to
        dataDir. Ownership is forced to hass:hass both on activation and before
        every service start.

        These are the files that can be edited from two directions: Home
        Assistant writes them (.HA_VERSION on every startup after a version
        change, the rest from its UI editors), while dataDir is also a git
        working tree an operator checks out as themselves. A checkout re-creates
        tracked files under the invoking user, which strips hass's write access
        and makes the service fail to start -- a fault that stays invisible until
        the next restart, since nothing rewrites these while HA is running.

        Only list paths Home Assistant genuinely writes. Config that hass merely
        reads (packages/, dashboards/, secrets.yaml) should stay operator-owned.
      '';
    };

    runtimeWritableDirs = mkOption {
      type = types.listOf types.str;
      default = [ ".storage" ];
      description = ''
        Directories under dataDir owned wholly by Home Assistant, relative to
        dataDir. Ownership is forced recursively to hass:hass; file modes are
        preserved so restrictive permissions (such as the 0600 credentials in
        .storage) survive the repair.
      '';
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

    mqtt = {
      server = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "mqtt://localhost:1883";
        description = "MQTT broker URL for Home Assistant integration.";
      };
      username = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "MQTT username for broker authentication.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "SOPS-managed secret containing the MQTT password.";
      };
      registerEmqxIntegration = mkOption {
        type = types.bool;
        default = true;
        description = "Automatically register credentials and ACLs with the EMQX integration module.";
      };
      allowedTopics = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Explicit MQTT topics to allow when registering with EMQX. Defaults to homeassistant/# and hass/#.";
      };
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

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to open firewall ports for Home Assistant.

        Opens the main HTTP port (cfg.port, default 8123).

        For HomeKit support, use homekit.openFirewall instead which
        manages the HomeKit-specific port range.

        Note: If using reverse proxy (Caddy) for external access, you
        may not need to open the main port directly.
      '';
    };

    homekit = {
      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to open firewall ports for HomeKit bridge integration.

          Opens TCP ports 21063-21068 for HomeKit accessory pairing and control.
          Required for iOS devices to discover and control Home Assistant
          via the HomeKit integration.
        '';
      };
      startPort = mkOption {
        type = types.port;
        default = 21063;
        description = "First port in the HomeKit port range.";
      };
      endPort = mkOption {
        type = types.port;
        default = 21068;
        description = "Last port in the HomeKit port range.";
      };
    };

    sonos = {
      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to open firewall ports for Sonos speaker integration.

          Opens TCP port 1400 which Sonos speakers use to send callbacks
          and notifications to Home Assistant.
        '';
      };
    };

    weatherflow = {
      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to open firewall ports for WeatherFlow Tempest integration.

          Opens UDP port 50222 which the WeatherFlow Tempest hub uses to
          broadcast weather data on the local network. Required for the
          local-only WeatherFlow integration to receive real-time updates.
        '';
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
        {
          assertion = !(cfg.mqtt.passwordFile != null && cfg.mqtt.username == null);
          message = "Home Assistant MQTT username must be provided when passwordFile is set.";
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
      # Note: Caddy handles WebSocket upgrades automatically - no special header manipulation needed
      modules.services.caddy.virtualHosts.${serviceName} = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = cfg.port;
        };
        auth = cfg.reverseProxy.auth or null;
        security = cfg.reverseProxy.security or { };
        reverseProxyBlock = cfg.reverseProxy.extraConfig or "";
      };

      # EMQX MQTT integration - auto-register user and ACLs
      modules.services.emqx.integrations.${serviceName} = mkIf
        (
          cfg.mqtt.registerEmqxIntegration &&
          cfg.mqtt.username != null &&
          cfg.mqtt.passwordFile != null
        )
        (
          let
            mqttAclTopics =
              if cfg.mqtt.allowedTopics != [ ] then
                cfg.mqtt.allowedTopics
              else
                [
                  "homeassistant/#"
                  "hass/#"
                ];
          in
          {
            users = [
              {
                username = cfg.mqtt.username;
                passwordFile = cfg.mqtt.passwordFile;
                tags = [ serviceName "home-automation" ];
              }
            ];
            acls = [
              {
                permission = "allow";
                action = "pubsub";
                subject = {
                  kind = "user";
                  value = cfg.mqtt.username;
                };
                topics = mqttAclTopics;
                comment = "${serviceName} MQTT integration for device discovery and control";
              }
            ];
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
        mode = "0770";
      };

      # Repair ownership on activation as well as at start, so a rebuild heals
      # drift even if the service is not restarted. "z"/"Z" only adjust paths
      # that already exist; Home Assistant creates them itself otherwise.
      # Modes are "-" throughout: only owner/group are corrected. Pinning a mode
      # here would strip the group-write that lets an operator hand-edit
      # scripts.yaml/scenes.yaml. Recovering from a read-only mode is left to
      # the start-time repair, which is what actually has to guarantee startup.
      systemd.tmpfiles.rules =
        map (path: "z ${path} - hass hass -") absWritableFiles
        ++ map (path: "Z ${path} - hass hass -") absWritableDirs;

      # Systemd unit coordination
      systemd.services.${serviceName} = {
        # NOTE: `attrs // (mkIf cond { ... })` must not be used here. It splices
        # `_type = "if"` into the attrset, so the module system reads the whole
        # definition as an mkIf and keeps only the mkIf body -- silently
        # dropping every sibling attribute. That is why RequiresMountsFor below
        # never reached the generated unit. optionalAttrs composes plainly.
        unitConfig = {
          RequiresMountsFor = [ cfg.dataDir ];

          # Home Assistant takes ~3s to fail, so systemd's default 10s window
          # can never accumulate 5 failures: a permanently broken instance
          # restarts forever while `systemctl is-active` still reports "active",
          # hiding the outage. Widen the window past the failure interval so a
          # persistent fault lands the unit in "failed" and stays there.
          #
          # This is also what makes the service's own ServiceDown alert usable:
          # that rule is `for = "2m"` on node_systemd_unit_state{state="active"}
          # == 0, and a flapping unit never holds the condition long enough to
          # fire (measured during the 2026-08-16 outage: 60s of contiguous zero
          # against a 120s requirement, so it went pending and reset for 43
          # minutes). Only a unit that reaches `failed` holds it.
          #
          # mkDefault so a host-level restart policy can own the number without
          # colliding with this module-level baseline.
          StartLimitIntervalSec = mkDefault 300;
          StartLimitBurst = mkDefault 5;
        } // (lib.optionalAttrs (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          OnFailure = [ "notify@home-assistant-failure:%n.service" ];
        });
        requires = mkIf (cfg.preseed.enable && !allowEmptyBootstrap) [ "preseed-${serviceName}.service" ];
        wants = mkIf (cfg.preseed.enable && allowEmptyBootstrap) [ "preseed-${serviceName}.service" ];
        after = mkIf cfg.preseed.enable [ "preseed-${serviceName}.service" ];
        environment = mkIf (cfg.extraLibs != [ ]) {
          LD_LIBRARY_PATH = lib.makeLibraryPath cfg.extraLibs;
        };
        # `ReadWritePaths = mkForce [ cfg.dataDir ]` used to sit here. It was
        # inert for the same mkIf reason, and reviving it would have been a
        # regression: upstream already grants dataDir, and forcing the list
        # would have dropped the media share (/mnt/data/media) that Home
        # Assistant writes generated content to. Removed rather than restored.
        serviceConfig =
          ({
            WorkingDirectory = mkForce cfg.dataDir;

            # mkBefore so this runs ahead of the upstream module's pre-start
            # script, and "+" so it runs as root -- hass cannot chown away files
            # it does not own, which is the whole failure mode being repaired.
            ExecStartPre = mkBefore [ "+${ownershipRepair}" ];
          }
          # See the unitConfig note above: optionalAttrs, never `// mkIf`.
          // (lib.optionalAttrs (cfg.environmentFiles != [ ]) {
            EnvironmentFile = cfg.environmentFiles;
          }));
      };

      # Ensure native Home Assistant account follows repo-wide conventions
      users.users.hass = {
        uid = mkForce serviceIds.uid;
        home = mkForce "/var/empty";
        createHome = mkForce false;
        isSystemUser = mkForce true;
        group = mkDefault "hass";
      };

      users.groups.hass = {
        gid = mkForce serviceIds.gid;
      };

      # Firewall rules for LAN access (opt-in)
      networking.firewall.allowedTCPPorts =
        lib.optional cfg.openFirewall cfg.port
        ++ lib.optionals cfg.homekit.openFirewall (lib.range cfg.homekit.startPort cfg.homekit.endPort)
        ++ lib.optional cfg.sonos.openFirewall 1400;

      # UDP ports for IoT integrations
      networking.firewall.allowedUDPPorts =
        lib.optional cfg.weatherflow.openFirewall 50222;

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
        inherit allowEmptyBootstrap;
        owner = "hass";
        group = "hass";
      }
    ))
  ];
}
