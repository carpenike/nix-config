{ lib
, pkgs
, config
, ...
}:
let
  cfg = config.modules.notifications;
  ntfyCfg = cfg.ntfy;

  # Priority mapping: string name to ntfy priority
  priorityMap = {
    min = "min";
    low = "low";
    normal = "default";
    default = "default";
    high = "high";
    urgent = "urgent";
  };

  getPriority = priority: priorityMap.${priority} or "default";

  # Script to send ntfy notification
  mkNtfyScript =
    { title
    , message
    , priority ? "default"
    , tags ? [ ]
    , url ? null
    ,
    }: ''
      set -euo pipefail

      # Determine topic URL
      TOPIC_URL="${if ntfyCfg.topic != "" then ntfyCfg.topic else "${ntfyCfg.server}"}"

      if [ -z "$TOPIC_URL" ]; then
        echo "ERROR: ntfy topic not configured" >&2
        exit 1
      fi

      # Build tags string
      TAGS="${lib.concatStringsSep "," tags}"

      # Send notification with retries
      MAX_RETRIES=${toString ntfyCfg.retryAttempts}
      TIMEOUT=${toString ntfyCfg.timeout}
      RETRY_COUNT=0
      SUCCESS=false

      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        HTTP_CODE=$(${pkgs.curl}/bin/curl -s -w "%{http_code}" -o /dev/null \
          --max-time "$TIMEOUT" \
          -H "Title: ${title}" \
          -H "Priority: ${getPriority priority}" \
          ${lib.optionalString (tags != []) ''-H "Tags: $TAGS"''} \
          ${lib.optionalString (url != null) ''-H "Click: ${url}"''} \
          -d "${message}" \
          "$TOPIC_URL" || echo "000")

        if [ "$HTTP_CODE" = "200" ]; then
          echo "ntfy notification sent successfully (HTTP $HTTP_CODE)"
          SUCCESS=true
          break
        else
          RETRY_COUNT=$((RETRY_COUNT + 1))
          if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo "ntfy notification failed (HTTP $HTTP_CODE), retrying ($RETRY_COUNT/$MAX_RETRIES)..." >&2
            sleep 2
          else
            echo "ntfy notification failed after $MAX_RETRIES attempts (HTTP $HTTP_CODE)" >&2
          fi
        fi
      done

      if [ "$SUCCESS" = "false" ]; then
        exit 1
      fi
    '';
in
{
  config = lib.mkIf (cfg.enable && ntfyCfg.enable) {
    # Validate configuration
    assertions = [
      {
        assertion = ntfyCfg.topic != "" || ntfyCfg.server != "";
        message = "modules.notifications.ntfy.topic or server must be set when ntfy is enabled";
      }
    ];

    # Generic notification service template using ntfy
    systemd.services."notify-ntfy@" = {
      description = "Send ntfy notification for %i";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      # Service receives parameters via environment variables:
      # NOTIFY_TITLE, NOTIFY_MESSAGE, NOTIFY_PRIORITY, NOTIFY_TAGS, NOTIFY_URL
      script = ''
        TITLE="''${NOTIFY_TITLE:-%i}"
        MESSAGE="''${NOTIFY_MESSAGE:-Notification from ${cfg.hostname}}"
        PRIORITY="''${NOTIFY_PRIORITY:-default}"
        TAGS="''${NOTIFY_TAGS:-}"
        URL="''${NOTIFY_URL:-}"

        ${mkNtfyScript {
          title = "$TITLE";
          message = "$MESSAGE";
          priority = "$PRIORITY";
          tags = [ "$TAGS" ];
          url = "$URL";
        }}
      '';
    };

    # Pre-defined notification services for common events

    # Backup success notification
    systemd.services."notify-ntfy-backup-success@" = lib.mkIf cfg.templates.backup-success.enable {
      description = "Backup success notification for %i via ntfy";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = mkNtfyScript {
        title = "Backup Success";
        message = "Backup completed successfully for %i on ${cfg.hostname} at $(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')";
        priority = cfg.templates.backup-success.priority;
        tags = [ "white_check_mark" "backup" "success" ];
      };
    };

    # Backup failure notification
    systemd.services."notify-ntfy-backup-failure@" = lib.mkIf cfg.templates.backup-failure.enable {
      description = "Backup failure notification for %i via ntfy";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = mkNtfyScript {
        title = "Backup Failed";
        message = "Backup failed for %i on ${cfg.hostname} at $(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S'). Check logs: journalctl -u %i";
        priority = cfg.templates.backup-failure.priority;
        tags = [ "x" "backup" "failure" "warning" ];
      };
    };

    # Service failure notification
    systemd.services."notify-ntfy-service-failure@" = lib.mkIf cfg.templates.service-failure.enable {
      description = "Service failure notification for %i via ntfy";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = mkNtfyScript {
        title = "Service Failed";
        message = "Service %i failed on ${cfg.hostname} at $(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')";
        priority = cfg.templates.service-failure.priority;
        tags = [ "rotating_light" "service" "failure" ];
      };
    };

    # Boot notification
    systemd.services."notify-ntfy-boot" = lib.mkIf cfg.templates.boot-notification.enable {
      description = "Send boot notification via ntfy";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = mkNtfyScript {
        title = "System Boot";
        message = "${cfg.hostname} has booted at $(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')";
        priority = cfg.templates.boot-notification.priority;
        tags = [ "rocket" "boot" ];
      };
    };

    # Disk alert monitoring
    systemd.services."notify-ntfy-disk-alert" = lib.mkIf cfg.templates.disk-alert.enable {
      description = "Check disk usage and send alerts via ntfy";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = ''
        THRESHOLD=${toString cfg.templates.disk-alert.threshold}

        ${pkgs.coreutils}/bin/df -h | ${pkgs.gnugrep}/bin/grep -vE '^Filesystem|tmpfs|cdrom|loop' | \
        while read filesystem size used avail capacity mounted; do
          usage=$(echo "$capacity" | ${pkgs.gnused}/bin/sed 's/%//')
          if [ "$usage" -gt "$THRESHOLD" ]; then
            ${mkNtfyScript {
              title = "Disk Space Alert";
              message = "Disk usage above ${toString cfg.templates.disk-alert.threshold}% on ${cfg.hostname}: $mounted is $capacity full ($avail available)";
              priority = cfg.templates.disk-alert.priority;
              tags = [ "floppy_disk" "warning" "disk" ];
            }}
          fi
        done
      '';
    };

    # Timer for periodic disk alerts (if enabled)
    systemd.timers."notify-ntfy-disk-alert" = lib.mkIf cfg.templates.disk-alert.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
      };
    };
  };
}
