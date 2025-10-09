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
    # Create payload directory for IPC between notification services
    # Using 1777 (world-writable with sticky bit) for shared drop-box pattern:
    # - Any DynamicUser service can create files (world-writable)
    # - Only file owner or root can delete/rename files (sticky bit)
    # - Files are created with 0644 (world-readable) via UMask=0022
    systemd.tmpfiles.rules = [
      "d /run/notify 1777 root root -"
    ];

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
      path = with pkgs; [ coreutils jq bash curl gettext systemd gawk ];

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        # Don't try to create RuntimeDirectory - tmpfiles already creates /run/notify
        # Use standard umask to create world-readable files (0644) for IPC
        UMask = "0022";
        # DynamicUser enables ProtectSystem=strict by default, making most paths read-only
        # Explicitly allow writes to /run/notify for IPC
        ReadWritePaths = [ "/run/notify" ];
      };

      # Pass %i as command-line argument - systemd expands it in ExecStart directive
      scriptArgs = "%i";

      script = ''
        set -euo pipefail

        # Parse the instance string: template-name:instance-info
        # Receive instance string as $1 (passed via scriptArgs)
        INSTANCE_STRING="$1"
        TEMPLATE_NAME=$(echo "$INSTANCE_STRING" | cut -d: -f1)
        INSTANCE_INFO=$(echo "$INSTANCE_STRING" | cut -d: -f2-)

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

        # For OnFailure handlers, extract context from the failed unit
        # INSTANCE_INFO will be the unit name when called with %n (e.g., restic-backups-system.service)
        if [[ "$INSTANCE_INFO" == *.service ]] || [[ "$INSTANCE_INFO" == *.timer ]]; then
          FAILED_UNIT="$INSTANCE_INFO"
          echo "[notify] Detected failed unit: $FAILED_UNIT"

          # Extract last 10 lines of journal for error context
          # Using awk to properly escape newlines for JSON/HTML
          export NOTIFY_ERRORMESSAGE=$(journalctl --no-pager -n 10 -u "$FAILED_UNIT" 2>/dev/null | awk '{printf "%s\\n", $0}' || echo "No log available")

          # Extract job/dataset names from unit name patterns
          # Pattern: restic-backups-JOBNAME.service -> JOBNAME
          if [[ "$FAILED_UNIT" =~ ^restic-backups-(.+)\.service$ ]]; then
            export NOTIFY_JOBNAME="''${BASH_REMATCH[1]}"
            echo "[notify] Extracted job name: $NOTIFY_JOBNAME"

            # Try to extract repository URL from service environment
            REPO_URL=$(systemctl show "$FAILED_UNIT" --property=Environment 2>/dev/null | \
                       grep -oP 'RESTIC_REPOSITORY=\K[^ ]+' || echo "unknown")
            if [ "$REPO_URL" != "unknown" ]; then
              export NOTIFY_REPOSITORY="$REPO_URL"
              echo "[notify] Extracted repository: $NOTIFY_REPOSITORY"
            fi
          fi

          # Pattern: syncoid-DATASET.service -> DATASET (for ZFS replication)
          # Example: syncoid-rpool-safe-home.service -> rpool-safe-home
          if [[ "$FAILED_UNIT" =~ ^syncoid-(.+)\.service$ ]]; then
            export NOTIFY_DATASET="''${BASH_REMATCH[1]}"
            echo "[notify] Extracted dataset: $NOTIFY_DATASET"
          fi

          # Pattern: sanoid.service (no dataset in name, affects all datasets)
          if [[ "$FAILED_UNIT" == "sanoid.service" ]]; then
            export NOTIFY_DATASET="all-datasets"
            echo "[notify] Sanoid failure affects all datasets"
          fi
        fi

        # Export common variables for envsubst
        export hostname="${cfg.hostname}"
        export serviceName="$INSTANCE_INFO"

        # Transform NOTIFY_* environment variables to placeholder format
        # This allows services to use idiomatic names like NOTIFY_BOOT_TIME
        # which get transformed to ''${boottime} placeholders (lowercase, no underscores)
        for var in $(env | grep '^NOTIFY_' | cut -d= -f1); do
          value=$(printenv "$var")
          # Transform: NOTIFY_BOOT_TIME -> boottime
          placeholder=$(echo "$var" | sed 's/^NOTIFY_//' | tr '[:upper:]' '[:lower:]' | tr -d '_')
          export "$placeholder"="$value"
        done

        # Use envsubst for safe variable substitution
        TITLE=$(echo "$TITLE" | envsubst)
        BODY=$(echo "$BODY" | envsubst)

        echo "[notify] Dispatching to $BACKEND (template: $TEMPLATE_NAME, instance: $INSTANCE_INFO)"

        # Escape instance ID for safe use in filenames
        ESCAPED_ID=$(${pkgs.systemd}/bin/systemd-escape "$INSTANCE_STRING")
        PAYLOAD_FILE="/run/notify/$ESCAPED_ID.json"

        # Create JSON payload for the backend service
        # File will be automatically group-readable (0660) via umask
        ${pkgs.jq}/bin/jq -n \
          --arg title "$TITLE" \
          --arg message "$BODY" \
          --arg priority "$PRIORITY" \
          '{title: $title, message: $message, priority: $priority}' \
          > "$PAYLOAD_FILE"        # Dispatch to enabled backend(s)
        ${lib.optionalString cfg.pushover.enable ''
          if [ "$BACKEND" == "pushover" ] || [ "$BACKEND" == "all" ]; then
            echo "[notify] Dispatching to Pushover..."
            systemctl start "notify-pushover@$ESCAPED_ID.service" || true
          fi
        ''}

        ${lib.optionalString cfg.ntfy.enable ''
          if [ "$BACKEND" == "ntfy" ] || [ "$BACKEND" == "all" ]; then
            echo "[notify] Dispatching to ntfy..."
            systemctl start "notify-ntfy@$ESCAPED_ID.service" || true
          fi
        ''}

        ${lib.optionalString cfg.healthchecks.enable ''
          if [ "$BACKEND" == "healthchecks" ] || [ "$BACKEND" == "all" ]; then
            echo "[notify] Dispatching to Healthchecks.io..."
            systemctl start "notify-healthchecks@$ESCAPED_ID.service" || true
          fi
        ''}

        echo "[notify] Notification dispatch complete"
      '';
    };

    # Enable the notification backends based on configuration
    # Individual backend implementations are in their respective modules
  };
}
