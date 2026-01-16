# hosts/forge/services/mealie.nix
#
# Host-specific configuration for Mealie on 'forge'.
# Mealie is a self-hosted recipe management application.

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "mealie.${domain}";
  dataset = "tank/services/mealie";
  dataDir = "/var/lib/mealie";
  pocketIdIssuer = "https://id.${domain}";
  listenAddr = "127.0.0.1";
  listenPortNumber = 9925;
  serviceEnabled = config.modules.services.mealie.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.mealie = {
        enable = true;
        dataDir = dataDir;
        datasetPath = dataset;
        image = "ghcr.io/mealie-recipes/mealie:v3.9.2@sha256:57713693dceca9a124f00f165eaf8f5c41de757e7f63f8a7b80625488605dc61";
        listenAddress = listenAddr;
        listenPort = listenPortNumber;
        allowSignup = false;
        defaults = {
          email = "recipes@${domain}";
          group = "Holthome";
          household = "Family";
        };

        database = {
          engine = "postgres";
          host = "host.containers.internal";
          port = 5432;
          name = "mealie";
          user = "mealie";
          passwordFile = config.sops.secrets."mealie/database_password".path;
          manageDatabase = true;
          localInstance = true;
          extensions = [{ name = "pg_trgm"; }];
        };

        smtp = {
          enable = true;
          host = "smtp.mailgun.org";
          port = 587;
          username = "mealie@holthome.net";
          passwordFile = config.sops.secrets."mealie/smtp_password".path;
          fromName = "Holthome Recipes";
          fromEmail = "recipes@holthome.net";
          strategy = "TLS";
        };

        oidc = {
          enable = true;
          configurationUrl = "${pocketIdIssuer}/.well-known/openid-configuration";
          clientId = "mealie";
          clientSecretFile = config.sops.secrets."mealie/oidc_client_secret".path;
          providerName = "PocketID";
          userClaim = "email";
          nameClaim = "name";
          groupsClaim = "groups";
          userGroup = "family";
          adminGroup = "admins";
          scopes = [ "openid" "profile" "email" "groups" ]; # Added groups scope
          signupEnabled = false;
          autoRedirect = true;
          rememberMe = true;
        };

        # Override DNS for id.holthome.net to use internal Podman bridge IP
        # Required because the container can't reach Cloudflare-proxied domains
        # via hairpin NAT. Caddy listens on 10.89.0.1 for internal HTTPS traffic.
        extraHosts = {
          "id.holthome.net" = "10.89.0.1";
        };

        openai = {
          enable = true;
          apiKeyFile = config.sops.secrets."mealie/openai_api_key".path;
          model = "gpt-4o-mini";
          workers = 2;
          sendDatabaseData = true;
          enableImageServices = true;
        };

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = listenAddr;
            port = listenPortNumber;
          };
        };

        backup = forgeDefaults.mkBackupWithTags "mealie" [ "recipes" "mealie" "forge" ];

        notifications.enable = true;

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        # Resource limits - 7d peak (295M) × 2.5 = 738M, using 768M
        resources = {
          memory = "768M";
          memoryReservation = "384M";
          cpus = "1.0";
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "mealie";

      # Service availability alert
      modules.alerting.rules."mealie-service-down" =
        forgeDefaults.mkServiceDownAlert "mealie" "Mealie" "recipe management";
    })
  ];
}
