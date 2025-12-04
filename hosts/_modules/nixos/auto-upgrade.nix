# Auto-upgrade module for NixOS hosts
#
# Configures system.autoUpgrade to pull from GitHub and apply updates.
# Works with the update-flake-lock GitHub Action for centralized lock file management.
#
# Usage:
#   modules.autoUpgrade = {
#     enable = true;
#     # Optional overrides:
#     # schedule = "04:00";
#     # rebootWindow = { lower = "03:00"; upper = "05:00"; };
#   };
{ config, lib, ... }:

let
  cfg = config.modules.autoUpgrade;
  notificationsEnabled = config.modules.notifications.enable or false;
in
{
  options.modules.autoUpgrade = {
    enable = lib.mkEnableOption "automatic system upgrades from GitHub";

    flakeUrl = lib.mkOption {
      type = lib.types.str;
      default = "github:carpenike/nix-config";
      description = "GitHub flake URL to pull updates from";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "04:00";
      description = "Time to run auto-upgrade (24-hour format)";
    };

    randomizedDelay = lib.mkOption {
      type = lib.types.str;
      default = "30min";
      description = "Random delay to avoid thundering herd";
    };

    allowReboot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to allow automatic reboots when kernel changes";
    };

    rebootWindow = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          lower = lib.mkOption {
            type = lib.types.str;
            default = "03:00";
            description = "Start of reboot window (24-hour format)";
          };
          upper = lib.mkOption {
            type = lib.types.str;
            default = "05:00";
            description = "End of reboot window (24-hour format)";
          };
        };
      });
      default = null;
      description = "Time window during which reboots are allowed";
    };

    persistent = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run missed upgrades on next boot";
    };
  };

  config = lib.mkIf cfg.enable {
    system.autoUpgrade = {
      enable = true;
      flake = "${cfg.flakeUrl}#${config.networking.hostName}";
      dates = cfg.schedule;
      randomizedDelaySec = cfg.randomizedDelay;
      persistent = cfg.persistent;

      # Don't try to write lock file - we're pulling from GitHub
      flags = [ "--no-write-lock-file" ];

      # Reboot settings
      allowReboot = cfg.allowReboot;
      rebootWindow = lib.mkIf (cfg.rebootWindow != null) cfg.rebootWindow;
    };

    # Register notification template for upgrade failures
    modules.notifications.templates.nixos-upgrade-failure = lib.mkIf notificationsEnabled {
      enable = lib.mkDefault true;
      priority = lib.mkDefault "high";
      title = "NixOS Upgrade Failed";
      body = ''
        Automatic NixOS upgrade failed on ${config.networking.hostName}.

        Check logs with: journalctl -u nixos-upgrade.service -n 100
      '';
    };

    # Add failure notification via systemd
    systemd.services.nixos-upgrade = lib.mkIf notificationsEnabled {
      onFailure = [ "notify@nixos-upgrade-failure.service" ];
    };
  };
}
