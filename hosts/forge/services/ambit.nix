# Ambit - half-day outings planner for one household.
# Upstream: https://github.com/carpenike/ambit
#
# The upstream flake owns the package and hardened systemd units. Forge owns
# PostgreSQL provisioning, secrets, reverse proxy exposure, and monitoring.
# All durable application state lives in PostgreSQL and is protected by the
# shared pgBackRest PITR configuration.
#
# One-time setup:
#   1. Create a PocketID OIDC client named "ambit" with callbacks:
#        https://ambit.holthome.net/api/auth/callback
#        https://ambit.holthome.net/oauth/callback
#   2. Add the four `ambit` values documented in hosts/forge/secrets.nix to
#      hosts/forge/secrets.sops.yaml.
#   3. Apply forge, then seed once with `systemctl start ambit-seed.service`.

{ config, inputs, lib, pkgs, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };

  serviceName = "ambit";
  serviceDomain = "${serviceName}.${config.networking.domain}";
  listenPort = 3419;

  serviceEnabled = config.services.ambit.enable or false;
in
{
  imports = [
    inputs.ambit.nixosModules.default
  ];

  config = lib.mkMerge [
    {
      services.ambit = {
        enable = true;
        package = inputs.ambit.packages.${pkgs.stdenv.hostPlatform.system}.default;
        port = listenPort;
        publicBaseUrl = "https://${serviceDomain}";

        settings = {
          AMBIT_OIDC_ISSUER = "https://id.${config.networking.domain}";
          AMBIT_OIDC_CLIENT_ID = serviceName;
        };

        environmentFile = config.sops.templates."ambit-env".path;
        autoMigrate = true;
        openFirewall = false;
      };

      modules.services.postgresql.databases.${serviceName} = {
        owner = serviceName;
        ownerPasswordFile = config.sops.secrets."ambit/db_password".path;
        permissionsPolicy = "owner-readwrite+readonly-select";
      };

      # The upstream migration unit waits for PostgreSQL itself. Also require
      # forge's declarative provisioning unit so the role and database exist on
      # the first activation before Drizzle attempts to connect.
      systemd.services.ambit-migrate = {
        after = [ "postgresql-provision-databases.service" ];
        requires = [ "postgresql-provision-databases.service" ];
      };

      systemd.services.ambit-seed = {
        after = [ "postgresql-provision-databases.service" ];
        requires = [ "postgresql-provision-databases.service" ];
      };

      # Ambit implements browser OIDC and an embedded OAuth authorization
      # server for MCP clients, so Caddy must remain a pure pass-through.
      modules.services.caddy.virtualHosts.${serviceName} = {
        enable = true;
        hostName = serviceDomain;
        backend = {
          host = "127.0.0.1";
          port = listenPort;
        };
        cloudflare = {
          enable = true;
          tunnel = "forge";
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          serviceName
          "Ambit"
          "Half-day outings planner";

      modules.services.homepage.contributions.${serviceName} = {
        group = "Productivity";
        name = "Ambit";
        icon = "mdi-map-marker-path";
        href = "https://${serviceDomain}";
        description = "Household outings planner";
        siteMonitor = "http://127.0.0.1:${toString listenPort}";
      };

      # Probe the complete Cloudflare Tunnel -> Caddy -> Ambit path. The SPA
      # may serve directly or redirect to login when no session is present.
      modules.services.gatus.contributions.${serviceName} = {
        name = "Ambit";
        group = "Productivity";
        url = "https://${serviceDomain}";
        interval = "60s";
        conditions = [
          "[STATUS] == any(200, 302)"
          "[RESPONSE_TIME] < 5000"
        ];
        alerts = [{
          type = "pushover";
          sendOnResolved = true;
          failureThreshold = 3;
          successThreshold = 1;
        }];
      };
    })
  ];
}
