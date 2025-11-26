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
        image = "ghcr.io/mealie-recipes/mealie:v3.5.0@sha256:7f776bbb5457db7f58951c11e3aa881f0167675a78459d7a7f2cd5e42d181fa5";
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
          extensions = [ { name = "pg_trgm"; } ];
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
          providerName = "Holthome SSO";
          userClaim = "email";
          nameClaim = "name";
          groupsClaim = "groups";
          userGroup = "family";
          adminGroup = "admins";
          scopes = [ "openid" "profile" "email" ];
          signupEnabled = false;
          autoRedirect = true;
          rememberMe = true;
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

        backup = {
          enable = true;
          repository = "nas-primary";
          tags = [ "recipes" "mealie" ];
          zfsDataset = dataset;
        };

        notifications.enable = true;

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" "restic" ];

        resources = {
          memory = "1536M";
          memoryReservation = "768M";
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
