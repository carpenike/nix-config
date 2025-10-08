{
  lib,
  config,
  ...
}:
let
  cfg = config.modules.notifications;
in
{
  imports = [
    ./pushover.nix
    ./ntfy.nix
    ./healthchecks.nix
  ];

  options.modules.notifications = {
    enable = lib.mkEnableOption "centralized notification system";

    defaultBackend = lib.mkOption {
      type = lib.types.enum [ "pushover" "ntfy" "healthchecks" "all" ];
      default = "pushover";
      description = "Default notification backend to use when not specified";
    };

    # Common notification options
    hostname = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Hostname to include in notifications";
    };

    # Event templates configuration
    templates = {
      backup-success = {
        enable = lib.mkEnableOption "backup success notification template" // { default = true; };
        priority = lib.mkOption {
          type = lib.types.str;
          default = "normal";
          description = "Notification priority for backup success";
        };
      };

      backup-failure = {
        enable = lib.mkEnableOption "backup failure notification template" // { default = true; };
        priority = lib.mkOption {
          type = lib.types.str;
          default = "high";
          description = "Notification priority for backup failure";
        };
      };

      service-failure = {
        enable = lib.mkEnableOption "service failure notification template" // { default = true; };
        priority = lib.mkOption {
          type = lib.types.str;
          default = "high";
          description = "Notification priority for service failure";
        };
      };

      boot-notification = {
        enable = lib.mkEnableOption "boot notification template" // { default = false; };
        priority = lib.mkOption {
          type = lib.types.str;
          default = "normal";
          description = "Notification priority for boot notifications";
        };
      };

      disk-alert = {
        enable = lib.mkEnableOption "disk alert notification template" // { default = false; };
        priority = lib.mkOption {
          type = lib.types.str;
          default = "high";
          description = "Notification priority for disk alerts";
        };
        threshold = lib.mkOption {
          type = lib.types.int;
          default = 80;
          description = "Disk usage percentage threshold for alerts";
        };
      };
    };

    # Backend configurations are defined in their respective modules
    pushover = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Pushover notifications";

          tokenFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing Pushover API token";
          };

          userKeyFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing Pushover user key";
          };

          defaultPriority = lib.mkOption {
            type = lib.types.int;
            default = 0;
            description = "Default priority level (-2 to 2)";
          };

          defaultDevice = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Default device to send notifications to (null = all devices)";
          };

          enableHtml = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable HTML formatting in messages";
          };

          retryAttempts = lib.mkOption {
            type = lib.types.int;
            default = 3;
            description = "Number of retry attempts for failed notifications";
          };

          timeout = lib.mkOption {
            type = lib.types.int;
            default = 10;
            description = "Timeout in seconds for notification requests";
          };
        };
      };
      default = {};
      description = "Pushover notification backend configuration";
    };

    ntfy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "ntfy notifications";

          topic = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "ntfy.sh topic URL for notifications";
          };

          server = lib.mkOption {
            type = lib.types.str;
            default = "https://ntfy.sh";
            description = "ntfy server URL";
          };

          defaultPriority = lib.mkOption {
            type = lib.types.str;
            default = "default";
            description = "Default priority (min, low, default, high, urgent)";
          };

          retryAttempts = lib.mkOption {
            type = lib.types.int;
            default = 3;
            description = "Number of retry attempts for failed notifications";
          };

          timeout = lib.mkOption {
            type = lib.types.int;
            default = 10;
            description = "Timeout in seconds for notification requests";
          };
        };
      };
      default = {};
      description = "ntfy notification backend configuration";
    };

    healthchecks = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Healthchecks.io monitoring";

          baseUrl = lib.mkOption {
            type = lib.types.str;
            default = "https://hc-ping.com";
            description = "Healthchecks.io base URL";
          };

          uuidFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing Healthchecks.io UUID";
          };

          retryAttempts = lib.mkOption {
            type = lib.types.int;
            default = 3;
            description = "Number of retry attempts for failed pings";
          };

          timeout = lib.mkOption {
            type = lib.types.int;
            default = 10;
            description = "Timeout in seconds for ping requests";
          };
        };
      };
      default = {};
      description = "Healthchecks.io monitoring configuration";
    };
  };

  config = lib.mkIf cfg.enable {
    # Enable the notification backends based on configuration
    # Individual backend implementations are in their respective modules
  };
}
