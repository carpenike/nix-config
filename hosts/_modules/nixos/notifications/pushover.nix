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

    # Read tokens from systemd credentials
    PUSHOVER_TOKEN=$(${pkgs.systemd}/bin/systemd-creds cat PUSHOVER_TOKEN)
    PUSHOVER_USER=$(${pkgs.systemd}/bin/systemd-creds cat PUSHOVER_USER_KEY)

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
        LoadCredential = [
          "PUSHOVER_TOKEN:${pushoverCfg.tokenFile}"
          "PUSHOVER_USER_KEY:${pushoverCfg.userKeyFile}"
        ];
      };      # Service receives parameters via environment variables:
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

    # Legacy services removed - migrated to distributed architecture:
    # - notify-backup-success@ -> backup.nix
    # - notify-backup-failure@ -> backup.nix
    # - notify-boot -> system-notifications.nix
    # - notify-disk-alert -> system-notifications.nix (future)
    # - notify-service-failure@ kept as generic utility (below)

    # Generic service failure notification - kept as utility for ad-hoc/manual use
    # Can be triggered manually: systemctl start notify-service-failure@my-service
    systemd.services."notify-service-failure@" = {
      description = "Generic service failure notification for %i";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
        LoadCredential = [
          "PUSHOVER_TOKEN:${pushoverCfg.tokenFile}"
          "PUSHOVER_USER_KEY:${pushoverCfg.userKeyFile}"
        ];
      };

      script = mkPushoverScript {
        title = "⚠️ Service Failed";
        message = "<b>Service %i failed</b><small>\n<b>Host:</b> ${cfg.hostname}\n<b>Time:</b> $(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')\n\n<b>Status:</b>\n$(${pkgs.systemd}/bin/systemctl status %i --no-pager -l || true)</small>";
        priority = "high";
        html = true;
      };
    };
  };
}
