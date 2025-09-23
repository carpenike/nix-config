{
  lib,
  config,
  ...
}:
let
  cfg = config.modules.services.haproxy;
in
{
  imports = [ ./shared.nix ]; # Import the shared options module

  options.modules.services.haproxy = {
    enable = lib.mkEnableOption "haproxy";
    config = lib.mkOption {
      type = lib.types.lines;
      default = "";
    };

    useDnsDependency = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to add a dependency on bind service";
    };
  };

  config = lib.mkIf cfg.enable {
    services.haproxy = {
      enable = true;
      config = cfg.config;
    };

    # Note: firewall ports now managed by shared.nix when shared config is used

    # Conditionally add systemd service configuration
    systemd.services.haproxy = lib.mkMerge [
      {
        # Ensure the service starts
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Restart = lib.mkOverride 500 "on-failure";
          RestartSec = "5s";
        };
      }

      # Only add these dependencies if useDnsDependency is true
      (lib.mkIf cfg.useDnsDependency {
        after = [
          "network.target"
          "network-online.target"
          "bind.service"
        ];
        requires = [
          "network.target"
          "bind.service"
        ];
        wants = [ "network-online.target" ];
      })
    ];
  };
}
