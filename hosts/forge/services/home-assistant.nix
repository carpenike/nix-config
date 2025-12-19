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

        # MQTT integration with EMQX broker
        mqtt = {
          server = "mqtt://127.0.0.1:1883";
          username = "home-assistant";
          passwordFile = config.sops.secrets."home-assistant/mqtt-password".path;
          # registerEmqxIntegration = true; # default - auto-registers user + ACLs
          # Default topics: homeassistant/# and hass/#
        };

        declarativeConfig = {
          default_config = { };
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
          };
          http = {
            server_host = [ "0.0.0.0" "::" ];
            server_port = 8123;
            use_x_forwarded_for = true;
            trusted_proxies = [
              "127.0.0.1"
              "10.88.0.0/16"
              "fc00::/7"
            ];
            ip_ban_enabled = true;
            login_attempts_threshold = 5;
          };
          history = { };
          logbook = { };
          frontend = { };
          conversation = { };
          lovelace = {
            mode = "storage";
            resources = [ ];
            dashboards = {
              lovelace-home = {
                mode = "yaml";
                title = "Home";
                icon = "mdi:home";
                show_in_sidebar = true;
                filename = "dashboards/home.yaml";
              };
              lovelace-mobile = {
                mode = "yaml";
                title = "Mobile";
                icon = "mdi:cellphone";
                show_in_sidebar = true;
                filename = "dashboards/mobile.yaml";
              };
            };
          };
          automation = "!include automations.yaml";
          logger = {
            default = "warning";
            logs = {
              "homeassistant.components.http" = "warning";
              "homeassistant.components.recorder" = "warning";
            };
          };
          recorder = {
            db_url = "!env_var HA_POSTGRES_URL";
            commit_interval = 1;
            auto_purge = true;
            purge_keep_days = 30;
            db_max_retries = 10;
          };
          tts = [
            {
              platform = "microsoft";
              api_key = "!env_var SECRET_MSFT_TTS_API_KEY";
            }
          ];
          amcrest = [
            {
              host = "10.50.50.101";
              username = "admin";
              password = "!env_var SECRET_AMCREST_PASSWORD";
            }
          ];
        };

        # Backup using forgeDefaults helper with home automation tags
        backup = forgeDefaults.mkBackupWithTags "home-assistant" (forgeDefaults.backupTags.home ++ [ "home-assistant" "forge" ]);

        # Disaster recovery preseed - restores from syncoid or restic before first start
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        # Upstream nixpkgs is currently missing several runtime dependencies
        # required by Home Assistant's default_config bundle. Provide them here
        # until the packaged closure includes the Python wheels directly.
        extraPackages = python3Packages:
          with python3Packages;
          [
            # Pushover notifications
            pushover-complete

            # HomeKit integration
            hap-python
            pychromecast
            base36

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
            jsonpath
            aiohttp-sse
            mcp
            pyipp
            beautifulsoup4
            androidtvremote2
            pysmlight

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
