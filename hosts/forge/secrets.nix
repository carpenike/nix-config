{ pkgs
, config
, lib
, ...
}:
let
  inherit (lib) optionalAttrs;

  autheliaEnabled = config.modules.services.authelia.enable or false;
  # Use the new unified backup system (modules.services.backup)
  backupEnabled = config.modules.services.backup.enable or false;
  resticEnabled = backupEnabled && (config.modules.services.backup.restic.enable or false);
  sanoidEnabled = config.modules.backup.sanoid.enable or false;
  alertingEnabled = config.modules.alerting.enable or false;
  dispatcharrEnabled = config.modules.services.dispatcharr.enable or false;
  homeAssistantEnabled = config.modules.services.home-assistant.enable or false;
  caddyEnabled = config.modules.services.caddy.enable or false;
  cloudflaredEnabled = config.modules.services.cloudflared.enable or false;
  cooklangEnabled = config.modules.services.cooklang.enable or false;
  cooklangFederationEnabled = config.modules.services.cooklangFederation.enable or false;
  grafanaEnabled = config.modules.services.grafana.enable or false;
  pocketIdEnabled = config.modules.services.pocketid.enable or false;
  esphomeEnabled = config.modules.services.esphome.enable or false;
  sonarrEnabled = config.modules.services.sonarr.enable or false;
  radarrEnabled = config.modules.services.radarr.enable or false;
  prowlarrEnabled = config.modules.services.prowlarr.enable or false;
  bazarrEnabled = config.modules.services.bazarr.enable or false;
  recyclarrEnabled = config.modules.services.recyclarr.enable or false;
  teslamateEnabled = config.modules.services.teslamate.enable or false;
  zigbeeEnabled = config.modules.services.zigbee2mqtt.enable or false;
  zwaveEnabled = config.modules.services."zwave-js-ui".enable or false;
  mealieEnabled = config.modules.services.mealie.enable or false;
  emqxEnabled = config.modules.services.emqx.enable or false;
  crossSeedEnabled = config.modules.services."cross-seed".enable or false;
  sabnzbdEnabled = config.modules.services.sabnzbd.enable or false;
  autobrrEnabled = config.modules.services.autobrr.enable or false;
  quiEnabled = config.modules.services.qui.enable or false;
  homepageEnabled = config.modules.services.homepage.enable or false;
  plexEnabled = config.modules.services.plex.enable or false;
  postgresqlEnabled =
    (config.modules.services.postgresql.enable or false)
    || (config.services.postgresql.enable or false);
  r2CredentialsEnabled = resticEnabled || postgresqlEnabled;
in
{
  config = {
    environment.systemPackages = [
      pkgs.sops
      pkgs.age
    ];

    sops = {
      defaultSopsFile = ./secrets.sops.yaml;
      age.sshKeyPaths = [
        "/etc/ssh/ssh_host_ed25519_key"
      ];
      secrets =
        { }
        // optionalAttrs resticEnabled {
          # Restic backup password (used for local NFS and R2 encryption)
          "restic/password" = {
            mode = "0400";
            owner = "restic-backup";
            group = "restic-backup";
          };

        }
        // optionalAttrs esphomeEnabled {
          "esphome/secrets.yaml" = {
            mode = "0400";
            owner = "esphome";
            group = "esphome";
            restartUnits = [ "esphome-sync-secrets.service" "podman-esphome.service" ];
          };
        }
        // optionalAttrs r2CredentialsEnabled {
          # Cloudflare R2 API credentials for offsite backups
          # Bucket: nix-homelab-prod-servers (forge, luna, nas-1)
          # Contains: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (R2 is S3-compatible)
          # Security: Scoped token with access ONLY to production-servers bucket
          # Used by: restic-backup service AND pgBackRest (postgres user needs read access)
          "restic/r2-prod-env" = {
            mode = "0440";
            owner = "restic-backup";
            group = "restic-backup";
          };

          # Future: additional R2 credential files live here as well
        }
        // optionalAttrs sanoidEnabled {
          # ZFS replication SSH key
          # Ephemeral secret (preferred): do not set a persistent path so sops-nix
          # writes the decrypted key under /run/secrets and we reference it via
          # config.sops.secrets."zfs-replication/ssh-key".path
          "zfs-replication/ssh-key" = {
            mode = "0600";
            owner = "zfs-replication";
            group = "zfs-replication";
          };
        }
        // optionalAttrs alertingEnabled {
          # Pushover notification credentials (for Alertmanager)
          # Alertmanager needs to read these files
          "pushover/token" = {
            mode = "0440";
            owner = "root";
            group = "alertmanager";
          };
          "pushover/user-key" = {
            mode = "0440";
            owner = "root";
            group = "alertmanager";
          };

          # Healthchecks.io webhook URL for dead man's switch
          "monitoring/healthchecks-url" = {
            mode = "0440";
            owner = "root";
            group = "alertmanager";
          };
        }
        // optionalAttrs dispatcharrEnabled {
          # PostgreSQL database passwords
          # Group-readable so postgresql-provision-databases.service (runs as postgres user)
          # can hash the file for change detection. PostgreSQL server reads via pg_read_file()
          # which has superuser privileges and doesn't need filesystem permissions.
          "postgresql/dispatcharr_password" = {
            mode = "0440"; # owner+group read
            owner = "root";
            group = "postgres";
          };
        }
        // optionalAttrs homeAssistantEnabled {
          "postgresql/home-assistant_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          "home-assistant/env" = {
            mode = "0400";
            owner = "hass";
            group = "hass";
            restartUnits = [ "home-assistant.service" ];
          };
        }
        // optionalAttrs caddyEnabled {
          # Cloudflare API token for Caddy DNS-01 ACME challenges
          # Reusing the same token structure as Luna for consistency
          "networking/cloudflare/ddns/apiToken" = {
            mode = "0400";
            owner = "caddy";
            group = "caddy";
          };

          # Loki Basic Auth password hash for Caddy reverse proxy (environment variable)
          "services/caddy/environment/loki-admin-bcrypt" = {
            mode = "0400";
            owner = "caddy";
            group = "caddy";
          };

          # Prometheus API key for backup taskfile (used by Caddy static API key auth)
          "prometheus/api-keys/backup-taskfile" = {
            mode = "0400";
            owner = "caddy";
            group = "caddy";
          };

          # Loki Basic Auth password hash for Caddy reverse proxy (file-based)
          "caddy/loki-admin-bcrypt" = {
            mode = "0400";
            owner = "caddy";
            group = "caddy";
          };
        }
        // optionalAttrs cloudflaredEnabled {
          # Cloudflare Tunnel credentials (JSON file)
          # Contains: AccountTag, TunnelSecret, TunnelID, TunnelName
          # Created via: cloudflared tunnel create forge
          "networking/cloudflare/forge-credentials" = {
            mode = "0400";
            owner = config.users.users.cloudflared.name;
            group = config.users.groups.cloudflared.name;
          };

          "networking/cloudflare/origin-cert" = {
            mode = "0400";
            owner = config.users.users.cloudflared.name;
            group = config.users.groups.cloudflared.name;
          };
        }
        // optionalAttrs cooklangEnabled {
          "resilio/cooklang-secret" = {
            mode = "0400";
            owner = "rslsync";
            group = config.modules.services.cooklang.group;
          };
        }
        // optionalAttrs cooklangFederationEnabled {
          "github/cooklang-token" = {
            mode = "0400";
            owner = config.modules.services.cooklangFederation.user;
            group = config.modules.services.cooklangFederation.group;
          };
        }
        // optionalAttrs grafanaEnabled {
          # Grafana admin password
          "grafana/admin-password" = {
            mode = "0400";
            owner = "grafana";
            group = "grafana";
          };

          # Grafana OIDC client secret (must match identity provider)
          "grafana/oidc_client_secret" = {
            mode = "0400";
            owner = "grafana";
            group = "grafana";
          };
        }
        // optionalAttrs pocketIdEnabled {
          # Pocket ID secrets
          "pocketid/environment" = {
            mode = "0400";
            owner = "pocket-id";
            group = "pocket-id";
          };

          "pocketid/encryption_key" = {
            mode = "0400";
            owner = "pocket-id";
            group = "pocket-id";
          };

          "pocketid/smtp_password" = {
            mode = "0400";
            owner = "pocket-id";
            group = "pocket-id";
          };

          "caddy/pocket-id-client-secret" = {
            mode = "0400";
            owner = "caddy";
            group = "caddy";
          };
        }
        // optionalAttrs autheliaEnabled {
          # Authelia secrets
          "authelia/jwt_secret" = {
            mode = "0400";
            owner = "authelia-main";
            group = "authelia-main";
          };

          "authelia/session_secret" = {
            mode = "0400";
            owner = "authelia-main";
            group = "authelia-main";
          };

          "authelia/storage_encryption_key" = {
            mode = "0400";
            owner = "authelia-main";
            group = "authelia-main";
          };

          "authelia/oidc/hmac_secret" = {
            mode = "0400";
            owner = "authelia-main";
            group = "authelia-main";
          };

          "authelia/oidc/issuer_private_key" = {
            mode = "0400";
            owner = "authelia-main";
            group = "authelia-main";
          };

          "authelia/oidc/grafana_client_secret" = {
            mode = "0400";
            owner = "authelia-main";
            group = "authelia-main";
          };

          "authelia/smtp_password" = {
            mode = "0400";
            owner = "authelia-main";
            group = "authelia-main";
          };

          "authelia/users.yaml" = {
            path = "/var/lib/authelia-main/users.yaml";
            mode = "0400";
            owner = "authelia-main";
            group = "authelia-main";
          };
        }
        // optionalAttrs sonarrEnabled {
          # *arr service API keys (for cross-service integration)
          # Sonarr injects these via SONARR__AUTH__APIKEY env vars
          "sonarr/api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs radarrEnabled {
          "radarr/api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs prowlarrEnabled {
          "prowlarr/api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs crossSeedEnabled {
          "cross-seed/api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs plexEnabled {
          # Plex token for API access (used by Homepage widget)
          # Get token from: https://www.plexopedia.com/plex-media-server/general/plex-token/
          "plex/token" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs teslamateEnabled {
          "teslamate/database_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          "teslamate/encryption_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "teslamate/mqtt_password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs zigbeeEnabled {
          "zigbee2mqtt/mqtt_password" = {
            mode = "0400";
            owner = "zigbee2mqtt";
            group = "zigbee2mqtt";
          };

          "zigbee2mqtt/network_key" = {
            mode = "0400";
            owner = "zigbee2mqtt";
            group = "zigbee2mqtt";
          };

          "zigbee2mqtt/pan_id" = {
            mode = "0400";
            owner = "zigbee2mqtt";
            group = "zigbee2mqtt";
          };

          "zigbee2mqtt/ext_pan_id" = {
            mode = "0400";
            owner = "zigbee2mqtt";
            group = "zigbee2mqtt";
          };
        }
        // optionalAttrs zwaveEnabled {
          "zwave-js-ui/mqtt_password" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/session_secret" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/s0_legacy_key" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/s2_unauthenticated_key" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/s2_authenticated_key" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/s2_access_control_key" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/s2_long_range_key" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/s2_long_range_access_control_key" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };
        }
        // optionalAttrs mealieEnabled {
          # Mealie service secrets
          "mealie/database_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          "mealie/smtp_password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "mealie/oidc_client_secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "mealie/openai_api_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs emqxEnabled {
          "emqx/dashboard_password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs sabnzbdEnabled {
          "sabnzbd/api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "sabnzbd/usenet/username" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "sabnzbd/usenet/password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs autobrrEnabled {
          "autobrr/session-secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "autobrr/oidc-client-secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs quiEnabled {
          "qui/oidc-client-secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        };

      # Templates for generating .env files for containers.
      # This is the correct pattern for injecting secrets into the environment
      # of OCI containers, as it defers secret injection until system activation time.
      templates =
        { }
        // optionalAttrs sonarrEnabled {
          "sonarr-env" = {
            content = ''
              SONARR__AUTH__APIKEY=${config.sops.placeholder."sonarr/api-key"}
              SONARR__LOG__LEVEL=Info
              SONARR__UPDATE__BRANCH=master
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs radarrEnabled {
          "radarr-env" = {
            content = ''
              RADARR__AUTH__APIKEY=${config.sops.placeholder."radarr/api-key"}
              RADARR__LOG__LEVEL=Info
              RADARR__UPDATE__BRANCH=master
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs prowlarrEnabled {
          "prowlarr-env" = {
            content = ''
              PROWLARR__AUTH__APIKEY=${config.sops.placeholder."prowlarr/api-key"}
              PROWLARR__LOG__LEVEL=Info
              PROWLARR__UPDATE__BRANCH=master
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs bazarrEnabled {
          "bazarr-env" = {
            content = ''
              SONARR_API_KEY=${config.sops.placeholder."sonarr/api-key"}
              RADARR_API_KEY=${config.sops.placeholder."radarr/api-key"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs recyclarrEnabled {
          "recyclarr-env" = {
            content = ''
              SONARR_MAIN_SONARR_API_KEY=${config.sops.placeholder."sonarr/api-key"}
              RADARR_MAIN_RADARR_API_KEY=${config.sops.placeholder."radarr/api-key"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs quiEnabled {
          "qui-env" = {
            content = ''
              QUI__OIDC_CLIENT_SECRET=${config.sops.placeholder."qui/oidc-client-secret"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs sabnzbdEnabled {
          "sabnzbd-env" = {
            content = ''
              SABNZBD__API_KEY=${config.sops.placeholder."sabnzbd/api-key"}
              SABNZBD__USENET__USERNAME=${config.sops.placeholder."sabnzbd/usenet/username"}
              SABNZBD__USENET__PASSWORD=${config.sops.placeholder."sabnzbd/usenet/password"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs autobrrEnabled {
          "autobrr-env" = {
            content = ''
              AUTOBRR__SESSION_SECRET=${config.sops.placeholder."autobrr/session-secret"}
              AUTOBRR__OIDC_CLIENT_SECRET=${config.sops.placeholder."autobrr/oidc-client-secret"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs homepageEnabled {
          # Homepage dashboard widget API keys
          # Re-uses existing arr service secrets for widget integration
          # Homepage reads HOMEPAGE_VAR_* directly as values (not file paths)
          "homepage-env" = {
            content = lib.concatStringsSep "\n" (lib.filter (x: x != "") [
              (lib.optionalString sonarrEnabled "HOMEPAGE_VAR_SONARR_API_KEY=${config.sops.placeholder."sonarr/api-key"}")
              (lib.optionalString radarrEnabled "HOMEPAGE_VAR_RADARR_API_KEY=${config.sops.placeholder."radarr/api-key"}")
              (lib.optionalString prowlarrEnabled "HOMEPAGE_VAR_PROWLARR_API_KEY=${config.sops.placeholder."prowlarr/api-key"}")
              (lib.optionalString sabnzbdEnabled "HOMEPAGE_VAR_SABNZBD_API_KEY=${config.sops.placeholder."sabnzbd/api-key"}")
              (lib.optionalString plexEnabled "HOMEPAGE_VAR_PLEX_TOKEN=${config.sops.placeholder."plex/token"}")
            ]);
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        };
    };
  };
}
