{
  lib,
  config,
  pkgs,
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

    # Distributed template system - services register their own templates
    templates = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "this notification template" // { default = true; };

          priority = lib.mkOption {
            type = lib.types.enum [ "emergency" "high" "normal" "low" "silent" ];
            default = "normal";
            description = ''
              Notification priority level:
              - emergency (2): Bypass quiet hours, require acknowledgment
              - high (1): Important but not critical
              - normal (0): Standard notifications
              - low (-1): No sound/vibration, show in notification center
              - silent (-2): No notification, log only
            '';
          };

          title = lib.mkOption {
            type = lib.types.str;
            description = "Title of the notification message. Can use placeholders like \${hostname}, \${serviceName}";
          };

          body = lib.mkOption {
            type = lib.types.lines;
            description = "Body of the notification message. Can use HTML formatting if backend supports it";
          };

          backend = lib.mkOption {
            type = lib.types.enum [ "pushover" "ntfy" "healthchecks" "all" ];
            default = cfg.defaultBackend;
            description = "Which backend(s) to use for this template";
          };

          # Template-specific options
          extraOptions = lib.mkOption {
            type = lib.types.attrs;
            default = {};
            description = "Additional template-specific options (e.g., disk threshold, retry count)";
          };
        };
      });
      default = {};
      description = ''
        Notification templates registered by service modules.
        Services define their own templates here using mkDefault for easy override.

        Example from backup.nix:
          modules.notifications.templates.backup-failure = {
            enable = lib.mkDefault true;
            priority = lib.mkDefault "high";
            title = "Backup Failed";
            body = "...";
          };
      '';
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
    # Generate a JSON file containing all registered template definitions
    # This is used by the generic dispatcher to look up template details
    environment.etc."notification-templates.json".text = builtins.toJSON (
      lib.mapAttrs (name: template: {
        inherit (template) enable priority backend title body;
        extraOptions = template.extraOptions or {};
      }) cfg.templates
    );

    # Generic notification dispatcher service
    # Services call this as: notify@template-name:instance-info.service
    # Example: notify@backup-failure:system-job.service
    systemd.services."notify@" = {
      description = "Notification dispatcher for %I";
      path = with pkgs; [ coreutils jq bash curl ];

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
      };

      script = ''
        set -euo pipefail

        # Parse the instance string: template-name:instance-info
        TEMPLATE_NAME=$(echo "%I" | cut -d: -f1)
        INSTANCE_INFO=$(echo "%I" | cut -d: -f2-)

        echo "[notify] Dispatching notification for template: $TEMPLATE_NAME, instance: $INSTANCE_INFO"

        # Load template configuration from JSON
        TEMPLATE_JSON=$(jq -r --arg name "$TEMPLATE_NAME" '.[$name] // empty' /etc/notification-templates.json)

        if [ -z "$TEMPLATE_JSON" ] || [ "$TEMPLATE_JSON" == "null" ]; then
          echo "[notify] ERROR: Template '$TEMPLATE_NAME' not found or not enabled"
          exit 1
        fi

        # Extract template details
        ENABLED=$(echo "$TEMPLATE_JSON" | jq -r '.enable // false')
        if [ "$ENABLED" != "true" ]; then
          echo "[notify] Template '$TEMPLATE_NAME' is disabled, skipping"
          exit 0
        fi

        PRIORITY=$(echo "$TEMPLATE_JSON" | jq -r '.priority // "normal"')
        TITLE=$(echo "$TEMPLATE_JSON" | jq -r '.title // "Notification"')
        BODY=$(echo "$TEMPLATE_JSON" | jq -r '.body // ""')
        BACKEND=$(echo "$TEMPLATE_JSON" | jq -r '.backend // "${cfg.defaultBackend}"')

        # Substitute common placeholders
        # Services can pass additional variables via NOTIFY_* environment variables
        HOSTNAME="${cfg.hostname}"
        TITLE=$(echo "$TITLE" | sed "s/\''${hostname}/$HOSTNAME/g" | sed "s/\''${serviceName}/$INSTANCE_INFO/g")
        BODY=$(echo "$BODY" | sed "s/\''${hostname}/$HOSTNAME/g" | sed "s/\''${serviceName}/$INSTANCE_INFO/g")

        # Also substitute any NOTIFY_* environment variables passed by the service
        for var in $(env | grep '^NOTIFY_' | cut -d= -f1); do
          value=$(eval echo \$$var)
          placeholder=$(echo "$var" | sed 's/^NOTIFY_//' | tr '[:upper:]' '[:lower:]')
          TITLE=$(echo "$TITLE" | sed "s/\''${$placeholder}/\''${value}/g")
          BODY=$(echo "$BODY" | sed "s/\''${$placeholder}/\''${value}/g")
        done

        echo "[notify] Title: $TITLE"
        echo "[notify] Priority: $PRIORITY"
        echo "[notify] Backend: $BACKEND"

        # Dispatch to enabled backend(s)
        ${lib.optionalString cfg.pushover.enable ''
          if [ "$BACKEND" == "pushover" ] || [ "$BACKEND" == "all" ]; then
            echo "[notify] Dispatching to Pushover..."
            # Call pushover notification service
            systemctl start "notify-pushover@$TEMPLATE_NAME:$INSTANCE_INFO.service" \
              --setenv=NOTIFY_TITLE="$TITLE" \
              --setenv=NOTIFY_MESSAGE="$BODY" \
              --setenv=NOTIFY_PRIORITY="$PRIORITY" || true
          fi
        ''}

        ${lib.optionalString cfg.ntfy.enable ''
          if [ "$BACKEND" == "ntfy" ] || [ "$BACKEND" == "all" ]; then
            echo "[notify] Dispatching to ntfy..."
            # Call ntfy notification service
            systemctl start "notify-ntfy@$TEMPLATE_NAME:$INSTANCE_INFO.service" \
              --setenv=NOTIFY_TITLE="$TITLE" \
              --setenv=NOTIFY_MESSAGE="$BODY" \
              --setenv=NOTIFY_PRIORITY="$PRIORITY" || true
          fi
        ''}

        ${lib.optionalString cfg.healthchecks.enable ''
          if [ "$BACKEND" == "healthchecks" ] || [ "$BACKEND" == "all" ]; then
            echo "[notify] Dispatching to Healthchecks.io..."
            # Call healthchecks notification service
            systemctl start "notify-healthchecks@$TEMPLATE_NAME:$INSTANCE_INFO.service" || true
          fi
        ''}

        echo "[notify] Notification dispatch complete"
      '';
    };

    # Enable the notification backends based on configuration
    # Individual backend implementations are in their respective modules
  };
}
