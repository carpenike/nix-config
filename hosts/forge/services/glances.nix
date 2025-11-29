# Glances System Monitoring
#
# Provides real-time system monitoring via web interface
# Used by Homepage dashboard for system stats widget

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.glances.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.glances = {
        enable = true;
        port = 61208;

        # Reverse proxy for external access
        reverseProxy = {
          enable = true;
          hostName = "glances.forge.holthome.net";
          # Uses PocketID/caddy-security for authentication
          caddySecurity = forgeDefaults.caddySecurity.admin;
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # Service availability alert
      modules.alerting.rules."glances-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "glances-web" "Glances" "system monitoring";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.glances = {
        group = "Infrastructure";
        name = "Glances";
        icon = "glances";
        href = "https://glances.forge.holthome.net";
        description = "System Monitoring";
        widget = {
          type = "glances";
          url = "http://localhost:61208";
          version = 4; # Glances v4+ requires this
          metric = "cpu";
        };
      };
    })
  ];
}
