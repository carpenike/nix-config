{ config, lib, pkgs, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  domain = config.networking.domain;
  haHostname = "ha.${domain}";
  haEnabled = config.modules.services.home-assistant.enable or false;
  recorderDatabase = "home_assistant";
  recorderUser = "hass_recorder";
  haDataDir = "/var/lib/home-assistant";
  mediaShare = "/mnt/media";
  allowlistedDirs = [ haDataDir mediaShare ];
  unstablePkgs = pkgs.unstable;
  dataset = "tank/services/home-assistant";
in
{
  config = lib.mkMerge [
    (lib.mkIf haEnabled {
      modules.services.postgresql.databases.${recorderDatabase} = {
        owner = recorderUser;
        ownerPasswordFile = config.sops.secrets."postgresql/home-assistant_password".path;
        extensions = [ "pg_trgm" ];
        permissionsPolicy = "owner-readwrite+readonly-select";
      };

      # Ensure Home Assistant waits for PostgreSQL when using the recorder database
      systemd.services.home-assistant = {
        wants = lib.mkAfter [ "postgresql.service" ];
        after = lib.mkAfter [ "postgresql.service" ];
      };
    })

    {
      modules.services.home-assistant = {
        enable = true;
        package = unstablePkgs.home-assistant;

        reverseProxy = {
          enable = true;
          hostName = haHostname;
        };

        dataDir = haDataDir;
        port = 8123;
        configWritable = false;
        environmentFiles = lib.optional haEnabled config.sops.secrets."home-assistant/env".path;

        declarativeConfig = {
          default_config = {};
          homeassistant = {
            name = "Home";
            internal_url = "https://${haHostname}";
            external_url = "https://${haHostname}";
            latitude = "!env_var SECRET_ZONE_HOME_LATITUDE";
            longitude = "!env_var SECRET_ZONE_HOME_LONGITUDE";
            elevation = "!env_var SECRET_ZONE_HOME_ELEVATION";
            time_zone = config.time.timeZone;
            unit_system = "us_customary";
            country = "US";
            currency = "USD";
            allowlist_external_dirs = allowlistedDirs;
            media_dirs = {
              media = mediaShare;
            };
            packages = "!include_dir_named packages";
            customize = "!include_dir_named customizations";
          };
          http = {
            use_x_forwarded_for = true;
            trusted_proxies = [
              "127.0.0.1"
              "10.88.0.0/16"
              "fc00::/7"
            ];
            ip_ban_enabled = true;
            login_attempts_threshold = 5;
          };
          history = {};
          logbook = {};
          frontend = {};
          conversation = {};
          automation = "!include automations.yaml";
          logger = {
            default = "info";
            logs = {
              "homeassistant.components.http" = "warning";
              "homeassistant.components.recorder" = "info";
            };
          };
          recorder = {
            db_url = "!env_var HA_POSTGRES_URL";
            commit_interval = 1;
            auto_purge = true;
            purge_keep_days = 30;
            db_max_retries = 10;
          };
        };

        # Backup using forgeDefaults helper with home automation tags
        backup = forgeDefaults.mkBackupWithTags "home-assistant" (forgeDefaults.backupTags.home ++ [ "home-assistant" "forge" ]);

        # Disaster recovery preseed - restores from syncoid or restic before first start
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        # Upstream nixpkgs is currently missing several runtime dependencies
        # required by Home Assistant's default_config bundle. Provide them here
        # until the packaged closure includes the Python wheels directly.
        extraPackages = python3Packages:
          let
            # Build async-upnp-client against the same Python toolchain Home Assistant uses
            asyncUpnpClient =
              python3Packages.callPackage
                "${unstablePkgs.path}/pkgs/development/python-modules/async-upnp-client/default.nix"
                { };

            # Same story for go2rtc-client, which isn't present in the narrowed package set
            go2rtcClient =
              python3Packages.callPackage
                "${unstablePkgs.path}/pkgs/development/python-modules/go2rtc-client/default.nix"
                { };

            zwaveJsServerPython =
              python3Packages.callPackage
                "${unstablePkgs.path}/pkgs/development/python-modules/zwave-js-server-python/default.nix"
                { };
            esphomeDashboardApi =
              python3Packages.esphome-dashboard-api or
              unstablePkgs.python3Packages.esphome-dashboard-api;

          in
          with python3Packages;
          [
            aiodiscover
            aiodhcpwatcher
            aiousbwatcher
            #asyncUpnpClient
            av
            #go2rtcClient
            #esphomeDashboardApi
            esphome-dashboard-api
            ical
            isal
            flatdict
            brotli
            aiogithubapi
            aioesphomeapi
            paho-mqtt
            pyserial
            pynacl
            faust-cchardet
            pymiele
            mysqlclient
            psycopg2
            #zwaveJsServerPython
            tesla-wall-connector
            bleak-esphome
            yalexs
            wyoming
            aiohue
            librouteros
            openai
            weatherflow4py
            pyweatherflowudp
            music-assistant-client
            python-otbr-api
            soco
            aioelectricitymaps
            aio-georss-client
            aio-georss-gdacs
            aiolifx
            aiowebostv
            python-ecobee-api
            aiomealie
            adb-shell
            pywaze
            caldav
            pyatv
            radios
            kegtron-ble
            ibeacon-ble
            yalexs-ble
            aiolifx-themes
            sonos-websocket
            androidtv
            go2rtc-client
            async-upnp-client
            zwave-js-server-python
            aiolifx-effects
            spotifyaio
            govee-ble
            plexapi
            plexwebsocket
            aiohomekit
            goveelights
            govee-local-api
            govee-led-wez
            govee-ble

          ];

        extraLibs = with pkgs; [ zlib-ng isa-l ];
      };

      services.home-assistant.customComponents = lib.mkIf haEnabled [
        unstablePkgs.home-assistant-custom-components.hass_web_proxy
      ];
    }

    # Infrastructure contributions (guarded by service enable)
    (lib.mkIf haEnabled {
      # Dataset replication via Sanoid
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "home-assistant";

      # Service availability alert (native systemd service)
      modules.alerting.rules."home-assistant-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "home-assistant" "HomeAssistant" "home automation";
    })
  ];
}
