{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.modules.notifications;
  pushoverCfg = cfg.pushover;

  # Priority mapping: string name to Pushover API integer
  priorityMap = {
    lowest = -2;
    low = -1;
    normal = 0;
    high = 1;
    urgent = 2;
  };

  getPriority = priority:
    if builtins.isInt priority then priority
    else priorityMap.${priority} or 0;

  # Script to send Pushover notification
  mkPushoverScript = {
    title,
    message,
    priority ? "normal",
    url ? null,
    urlTitle ? null,
    device ? null,
    html ? true,
  }: ''
    set -euo pipefail

    # Read tokens from files
    if [ -f "${pushoverCfg.tokenFile}" ]; then
      PUSHOVER_TOKEN=$(cat "${pushoverCfg.tokenFile}")
    else
      echo "ERROR: Pushover token file not found: ${pushoverCfg.tokenFile}" >&2
      exit 1
    fi

    if [ -f "${pushoverCfg.userKeyFile}" ]; then
      PUSHOVER_USER=$(cat "${pushoverCfg.userKeyFile}")
    else
      echo "ERROR: Pushover user key file not found: ${pushoverCfg.userKeyFile}" >&2
      exit 1
    fi

    # Build notification payload
    PRIORITY="${toString (getPriority priority)}"
    ${lib.optionalString (device != null) ''DEVICE="${device}"''}
    ${lib.optionalString (device == null && pushoverCfg.defaultDevice != null) ''DEVICE="${pushoverCfg.defaultDevice}"''}

    # Send notification with retries
    MAX_RETRIES=${toString pushoverCfg.retryAttempts}
    TIMEOUT=${toString pushoverCfg.timeout}
    RETRY_COUNT=0
    SUCCESS=false

    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
      HTTP_CODE=$(${pkgs.curl}/bin/curl -s -w "%{http_code}" -o /tmp/pushover-response.json \
        --max-time "$TIMEOUT" \
        --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "title=${title}" \
        --form-string "message=${message}" \
        --form-string "priority=$PRIORITY" \
        ${lib.optionalString html ''--form-string "html=1"''} \
        ${lib.optionalString (url != null) ''--form-string "url=${url}"''} \
        ${lib.optionalString (urlTitle != null) ''--form-string "url_title=${urlTitle}"''} \
        ${lib.optionalString (device != null || pushoverCfg.defaultDevice != null) ''--form-string "device=''${DEVICE:-}"''} \
        "https://api.pushover.net/1/messages.json" || echo "000")

      if [ "$HTTP_CODE" = "200" ]; then
        echo "Pushover notification sent successfully (HTTP $HTTP_CODE)"
        SUCCESS=true
        break
      else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
          echo "Pushover notification failed (HTTP $HTTP_CODE), retrying ($RETRY_COUNT/$MAX_RETRIES)..." >&2
          sleep 2
        else
          echo "Pushover notification failed after $MAX_RETRIES attempts (HTTP $HTTP_CODE)" >&2
          if [ -f /tmp/pushover-response.json ]; then
            echo "Response: $(cat /tmp/pushover-response.json)" >&2
          fi
        fi
      fi
    done

    rm -f /tmp/pushover-response.json

    if [ "$SUCCESS" = "false" ]; then
      exit 1
    fi
  '';
in
{
  config = lib.mkIf (cfg.enable && pushoverCfg.enable) {
    # Validate configuration (at build time)
    assertions = [
      {
        assertion = pushoverCfg.tokenFile != null;
        message = "modules.notifications.pushover.tokenFile must be set when Pushover is enabled";
      }
      {
        assertion = pushoverCfg.userKeyFile != null;
        message = "modules.notifications.pushover.userKeyFile must be set when Pushover is enabled";
      }
      # Note: We don't check pathExists here because sops secrets won't exist until runtime
    ];

    # Generic notification service template using Pushover
    systemd.services."notify-pushover@" = {
      description = "Send Pushover notification for %i";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      # Service receives parameters via environment variables:
      # NOTIFY_TITLE, NOTIFY_MESSAGE, NOTIFY_PRIORITY, NOTIFY_URL, NOTIFY_URL_TITLE
      script = ''
        TITLE="''${NOTIFY_TITLE:-%i}"
        MESSAGE="''${NOTIFY_MESSAGE:-Notification from ${cfg.hostname}}"
        PRIORITY="''${NOTIFY_PRIORITY:-normal}"
        URL="''${NOTIFY_URL:-}"
        URL_TITLE="''${NOTIFY_URL_TITLE:-}"

        ${mkPushoverScript {
          title = "$TITLE";
          message = "$MESSAGE";
          priority = "$PRIORITY";
          url = "$URL";
          urlTitle = "$URL_TITLE";
        }}
      '';
    };

    # Pre-defined notification services for common events

    # Backup success notification
    systemd.services."notify-backup-success@" = lib.mkIf cfg.templates.backup-success.enable {
      description = "Backup success notification for %i";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = mkPushoverScript {
        title = "✅ Backup Success";
        message = "<b>Backup completed successfully</b><small>\n<b>Service:</b> %i\n<b>Host:</b> ${cfg.hostname}\n<b>Time:</b> $(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')</small>";
        priority = cfg.templates.backup-success.priority;
        html = true;
      };
    };

    # Backup failure notification
    systemd.services."notify-backup-failure@" = lib.mkIf cfg.templates.backup-failure.enable {
      description = "Backup failure notification for %i";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = mkPushoverScript {
        title = "❌ Backup Failed";
        message = "<b>Backup failed</b><small>\n<b>Service:</b> %i\n<b>Host:</b> ${cfg.hostname}\n<b>Time:</b> $(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')\n\n<b>Action:</b> Check logs with:\njournalctl -u %i</small>";
        priority = cfg.templates.backup-failure.priority;
        html = true;
      };
    };

    # Service failure notification
    systemd.services."notify-service-failure@" = lib.mkIf cfg.templates.service-failure.enable {
      description = "Service failure notification for %i";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = mkPushoverScript {
        title = "⚠️ Service Failed";
        message = "<b>Service %i failed</b><small>\n<b>Host:</b> ${cfg.hostname}\n<b>Time:</b> $(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')\n\n<b>Status:</b>\n$(${pkgs.systemd}/bin/systemctl status %i --no-pager -l || true)</small>";
        priority = cfg.templates.service-failure.priority;
        html = true;
      };
    };

    # Boot notification
    systemd.services."notify-boot" = lib.mkIf cfg.templates.boot-notification.enable {
      description = "Send boot notification";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = mkPushoverScript {
        title = "🚀 System Boot";
        message = "<b>${cfg.hostname} has booted</b><small>\n<b>Time:</b> $(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')\n<b>Kernel:</b> $(${pkgs.coreutils}/bin/uname -r)\n<b>Uptime:</b> $(${pkgs.coreutils}/bin/uptime -p)</small>";
        priority = cfg.templates.boot-notification.priority;
        html = true;
      };
    };

    # Disk alert monitoring (runs periodically)
    systemd.services."notify-disk-alert" = lib.mkIf cfg.templates.disk-alert.enable {
      description = "Check disk usage and send alerts";

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
            ${mkPushoverScript {
              title = "💾 Disk Space Alert";
              message = "<b>Disk usage above threshold</b><small>\n<b>Host:</b> ${cfg.hostname}\n<b>Mount:</b> $mounted\n<b>Usage:</b> $capacity\n<b>Available:</b> $avail</small>";
              priority = cfg.templates.disk-alert.priority;
              html = true;
            }}
          fi
        done
      '';
    };

    # Timer for periodic disk alerts (if enabled)
    systemd.timers."notify-disk-alert" = lib.mkIf cfg.templates.disk-alert.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
      };
    };
  };
}
