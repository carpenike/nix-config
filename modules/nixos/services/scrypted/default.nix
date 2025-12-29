{ lib, mylib, pkgs, config, podmanLib, ... }:

let
  sharedTypes = mylib.types;
  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;
  cfg = config.modules.services.scrypted;
  storageCfg = config.modules.storage;
  serviceName = "scrypted";
  backend = config.virtualisation.oci-containers.backend;
  mainServiceUnit = "${backend}-${serviceName}.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/scrypted";
  domain = config.networking.domain or null;
  defaultHostname = if domain == null || domain == "" then "scrypted.local" else "scrypted.${domain}";
  hasCentralizedNotifications = config.modules.notifications.enable or false;

  dnsEnv = lib.listToAttrs (lib.imap0
    (idx: server: {
      name = "SCRYPTED_DNS_SERVER_${toString idx}";
      value = server;
    })
    cfg.dnsServers);

  baseEnv = {
    TZ = cfg.timezone;
  };

  nvrEnv = lib.optionalAttrs cfg.nvr.enable {
    SCRYPTED_NVR_VOLUME = cfg.nvr.containerPath;
  };

  mdnsEnv = lib.optionalAttrs (cfg.mdns.enable && cfg.mdns.mode == "container") {
    SCRYPTED_DOCKER_AVAHI = "true";
  };

  environment = baseEnv
    // nvrEnv
    // mdnsEnv
    // dnsEnv
    // cfg.extraEnv;

  baseVolumes = [
    "${cfg.dataDir}:/server/volume:rw"
  ];

  nvrVolume = lib.optionals cfg.nvr.enable [
    "${cfg.nvr.path}:${cfg.nvr.containerPath}:${cfg.nvr.mountMode}"
  ];

  mdnsHostVolumes = lib.optionals (cfg.mdns.enable && cfg.mdns.mode == "host") [
    # Mount full /var/run/dbus directory, not just the socket - required for DBus permissions
    "${cfg.mdns.host.dbusPath}:${cfg.mdns.host.dbusPath}:rw"
    "${cfg.mdns.host.avahiSocket}:${cfg.mdns.host.avahiSocket}:rw"
  ];

  volumes = baseVolumes ++ nvrVolume ++ mdnsHostVolumes ++ cfg.extraVolumes;

  hostNetworkOptions = lib.optionals cfg.hostNetwork [ "--network=host" ];

  privilegedOptions = lib.optionals cfg.privileged [ "--privileged" ];

  deviceOptions = map (device: "--device=${device}") cfg.devices;

  mdnsSecurityOptions = lib.optionals (cfg.mdns.enable && cfg.mdns.mode == "host") [
    "--security-opt=apparmor=unconfined"
  ];

  healthcheckOptions = lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
    "--health-cmd=curl --fail --silent --max-time 5 http://127.0.0.1:${toString cfg.httpPort}/ || exit 1"
    "--health-interval=${cfg.healthcheck.interval}"
    "--health-timeout=${cfg.healthcheck.timeout}"
    "--health-retries=${toString cfg.healthcheck.retries}"
    "--health-start-period=${cfg.healthcheck.startPeriod}"
  ];

  extraOptions = privilegedOptions
    ++ hostNetworkOptions
    ++ deviceOptions
    ++ mdnsSecurityOptions
    ++ healthcheckOptions
    ++ cfg.extraOptions;

  portMappings = lib.optionals (!cfg.hostNetwork) (
    let
      http = "${toString cfg.httpPort}:${toString cfg.httpPort}";
      https = "${toString cfg.httpsPort}:${toString cfg.httpsPort}";
    in
    [ http https ]
  );

  reverseProxyHost =
    if cfg.reverseProxy != null && cfg.reverseProxy.hostName != null then cfg.reverseProxy.hostName else cfg.hostname;

  defaultBackend = {
    scheme = "http";
    host = "127.0.0.1";
    port = cfg.httpPort;
  };

  reverseProxyBackend =
    if cfg.reverseProxy != null then lib.attrByPath [ "backend" ] { } cfg.reverseProxy else { };

  effectiveBackend = lib.recursiveUpdate defaultBackend reverseProxyBackend;

in
{
  options.modules.services.scrypted = {
    enable = lib.mkEnableOption "Scrypted NVR platform (containerized deployment)";

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/koush/scrypted:latest";
      description = "Container image reference for Scrypted (pin to a digest in production).";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = defaultHostname;
      description = "Friendly hostname used for reverse proxy + alerts.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/scrypted";
      description = "Configuration/state directory mounted at /server/volume inside the container.";
    };

    datasetName = lib.mkOption {
      type = lib.types.str;
      default = "scrypted";
      description = "services dataset attribute name used when manageStorage = true.";
    };

    dataOwner = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "Owner assigned to the configuration dataset mount.";
    };

    dataGroup = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "Group assigned to the configuration dataset mount.";
    };

    manageStorage = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Automatically declare ZFS datasets for Scrypted state directories.";
    };

    nvr = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Mount a dedicated volume for Scrypted NVR recordings.";
      };

      path = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/scrypted/nvr";
        description = "Host path backing the NVR storage mount.";
      };

      containerPath = lib.mkOption {
        type = lib.types.path;
        default = "/nvr";
        description = "Container path the NVR dataset will be mounted to.";
      };

      mountMode = lib.mkOption {
        type = lib.types.str;
        default = "rw";
        description = "Mount options for the NVR volume (e.g., rw, ro, z).";
      };

      datasetName = lib.mkOption {
        type = lib.types.str;
        default = "scrypted-nvr";
        description = "services dataset attribute name for the recordings dataset.";
      };

      owner = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "Owner assigned to the NVR dataset mount.";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "Group assigned to the NVR dataset mount.";
      };

      manageStorage = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically manage the NVR ZFS dataset when true.";
      };
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = config.time.timeZone or "UTC";
      description = "Timezone passed through to the container.";
    };

    hostNetwork = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the container on the host network (required for HomeKit/mDNS discovery).";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 11080;
      description = "HTTP port exposed by Scrypted (used for reverse proxy backend).";
    };

    httpsPort = lib.mkOption {
      type = lib.types.port;
      default = 10443;
      description = "HTTPS port exposed by Scrypted.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to open firewall ports for Scrypted.

        Opens httpPort and httpsPort for TCP connections.

        Note: This does NOT open HomeKit ports. Use homekit.openFirewall
        for HomeKit/mDNS access from Apple devices.

        Required for:
        - Direct access to Scrypted web interface (without reverse proxy)
        - API access from other services
      '';
    };

    homekit = {
      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to open firewall ports for HomeKit access.

          Opens:
          - UDP 5353 (mDNS) - Required for HomeKit device discovery
          - TCP ports for HAP (HomeKit Accessory Protocol)

          Required for:
          - Apple Home app to discover and control Scrypted accessories
          - HomeKit Secure Video streaming

          Note: Each HomeKit accessory in Scrypted uses its own HAP port.
          Configure these ports in Scrypted's HomeKit plugin settings,
          then add them to homekit.hapPorts.
        '';
      };

      hapPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        description = ''
          List of HAP (HomeKit Accessory Protocol) TCP ports to open.

          Each camera/accessory in Scrypted that's exposed to HomeKit uses
          its own HAP port. These are configurable in Scrypted's HomeKit
          plugin settings under each accessory.

          Add the port numbers you've configured in Scrypted here.
        '';
        example = [ 43929 47649 46523 ];
      };
    };

    dnsServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "1.1.1.1" "8.8.8.8" ];
      description = "DNS resolvers injected via SCRYPTED_DNS_SERVER_* env vars to avoid flaky ISP resolvers.";
    };

    privileged = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Run the container in privileged mode (needed only for advanced hardware passthrough scenarios).";
    };

    devices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''Device passthrough entries formatted like "/dev/bus/usb:/dev/bus/usb" or "/dev/dri:/dev/dri".'';
    };

    extraVolumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''Additional Podman volume bindings ("/host/path:/container/path[:options]").'';
    };

    extraOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra Podman CLI options appended to the container definition.";
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Additional environment variables passed to the container.";
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Environment files loaded into the container (for secrets or tuning knobs).";
    };

    mdns = {
      enable = lib.mkEnableOption "Expose mDNS/Avahi into the container for HomeKit and Google Home";

      mode = lib.mkOption {
        type = lib.types.enum [ "host" "container" ];
        default = "host";
        description = "Use the host's Avahi daemon (host) or run Avahi inside the container (container).";
      };

      host = {
        dbusPath = lib.mkOption {
          type = lib.types.path;
          default = "/var/run/dbus";
          description = "Host DBus directory forwarded when mdns.mode = host (must be full directory for permissions).";
        };

        avahiSocket = lib.mkOption {
          type = lib.types.path;
          default = "/var/run/avahi-daemon/socket";
          description = "Host Avahi socket forwarded when mdns.mode = host.";
        };
      };
    };

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Optional reverse proxy registration for the Scrypted UI.";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = mainServiceUnit;
        labels = {
          service = serviceName;
          service_type = "nvr";
        };
      };
      description = "Log shipping metadata for Scrypted.";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "system-alerts" ];
        customMessages.failure = "Scrypted container failed on ${config.networking.hostName}";
      };
      description = "Notification policy for service failures.";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Restic backup policy for Scrypted configuration data (recordings should be excluded).";
    };

    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Restic repository URL for restore operations";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to Restic password file";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., for B2 credentials)";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = ''
          Order and selection of restore methods to attempt. Methods are tried
          sequentially until one succeeds.
        '';
      };
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = null;
      description = "Optional Podman resource limits for the container.";
    };

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "120s";
      };
      description = "Container healthcheck configuration.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = !(cfg.mdns.enable && !cfg.hostNetwork);
            message = "Scrypted mDNS support requires hostNetwork = true.";
          }
        ] ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "Scrypted preseed.enable requires preseed.repositoryUrl to be set.";
        }) ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.passwordFile != null;
          message = "Scrypted preseed.enable requires preseed.passwordFile to be set.";
        });

        systemd.tmpfiles.rules =
          [
            "d ${cfg.dataDir} 0750 ${cfg.dataOwner} ${cfg.dataGroup} -"
          ]
          ++ lib.optionals cfg.nvr.enable [
            "d ${cfg.nvr.path} 0750 ${cfg.nvr.owner} ${cfg.nvr.group} -"
          ];

        # Firewall rules for Scrypted (opt-in)
        # Web interface ports are optional (access via reverse proxy recommended)
        # HomeKit ports required for Apple Home app integration
        networking.firewall = lib.mkMerge [
          # Main Scrypted ports (when openFirewall = true)
          (lib.mkIf cfg.openFirewall {
            allowedTCPPorts = [ cfg.httpPort cfg.httpsPort ];
          })

          # HomeKit ports (when homekit.openFirewall = true)
          (lib.mkIf cfg.homekit.openFirewall {
            # mDNS is required for HomeKit device discovery
            allowedUDPPorts = [ 5353 ];
            # HAP (HomeKit Accessory Protocol) ports - each camera/accessory needs one
            allowedTCPPorts = cfg.homekit.hapPorts;
          })
        ];

        virtualisation.oci-containers.containers.${serviceName} = podmanLib.mkContainer serviceName {
          image = cfg.image;
          environment = environment;
          environmentFiles = cfg.environmentFiles;
          volumes = volumes;
          extraOptions = extraOptions;
          resources = cfg.resources;
          ports = portMappings;
        };

        systemd.services.${mainServiceUnit} = lib.mkMerge [
          (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
            unitConfig.OnFailure = [ "notify@scrypted-failure:%n.service" ];
          })
          (lib.mkIf cfg.preseed.enable {
            wants = [ "preseed-scrypted.service" ];
            after = [ "preseed-scrypted.service" ];
          })
        ];

        modules.services.caddy.virtualHosts.${serviceName} = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          enable = true;
          hostName = reverseProxyHost;
          backend = effectiveBackend;
          auth = cfg.reverseProxy.auth;
          security = cfg.reverseProxy.security;
          extraConfig = cfg.reverseProxy.extraConfig;
        };

        modules.services.scrypted.reverseProxy.backend = lib.mkIf (cfg.reverseProxy != null) (lib.mkDefault defaultBackend);

        modules.storage.datasets.services.${cfg.datasetName} = lib.mkIf cfg.manageStorage {
          mountpoint = cfg.dataDir;
          recordsize = "16K";
          compression = "zstd";
          properties = { "com.sun:auto-snapshot" = "true"; };
          owner = cfg.dataOwner;
          group = cfg.dataGroup;
          mode = "0750";
        };

        modules.storage.datasets.services.${cfg.nvr.datasetName} = lib.mkIf (cfg.nvr.enable && cfg.nvr.manageStorage) {
          mountpoint = cfg.nvr.path;
          recordsize = "1M";
          compression = "lz4";
          properties = {
            "com.sun:auto-snapshot" = "true";
            atime = "off";
          };
          owner = cfg.nvr.owner;
          group = cfg.nvr.group;
          mode = "0750";
        };

        modules.backup.restic.jobs.${serviceName} = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
          enable = true;
          repository = cfg.backup.repository;
          paths = if (cfg.backup.paths != [ ]) then cfg.backup.paths else [ cfg.dataDir ];
          excludePatterns = (cfg.backup.excludePatterns or [ ]) ++ lib.optionals cfg.nvr.enable [ "${cfg.nvr.path}/**" ];
          frequency = cfg.backup.frequency;
          retention = cfg.backup.retention;
          tags = if (cfg.backup.tags != [ ]) then cfg.backup.tags else [ "scrypted" "nvr" "config" ];
          useSnapshots = cfg.backup.useSnapshots;
          zfsDataset = cfg.backup.zfsDataset;
          preBackupScript = cfg.backup.preBackupScript;
          postBackupScript = cfg.backup.postBackupScript;
        };
      }

      # Add the preseed service itself
      (lib.mkIf cfg.preseed.enable (
        storageHelpers.mkPreseedService {
          serviceName = "scrypted";
          dataset = datasetPath;
          mountpoint = cfg.dataDir;
          mainServiceUnit = mainServiceUnit;
          replicationCfg = null; # Replication config handled at host level
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
          owner = cfg.dataOwner;
          group = cfg.dataGroup;
        }
      ))
    ]
  );
}
