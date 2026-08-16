{ lib
, pkgs
, config
, ...
}:
let
  cfg = config.modules.notifications;
  ntfyCfg = cfg.ntfy;

  # Delivery script. Reads TITLE, MESSAGE and PRIORITY from the environment.
  deliverScript = ''
    set -uo pipefail

    TOPIC_URL="${if ntfyCfg.topic != "" then ntfyCfg.topic else ntfyCfg.server}"
    if [ -z "$TOPIC_URL" ]; then
      echo "[ntfy] ERROR: topic not configured" >&2
      return 1
    fi

    # Map the template priority vocabulary onto ntfy's.
    case "''${PRIORITY:-normal}" in
      emergency)      NTFY_PRIORITY="urgent" ;;
      high|urgent)    NTFY_PRIORITY="high" ;;
      normal|default) NTFY_PRIORITY="default" ;;
      low)            NTFY_PRIORITY="low" ;;
      silent|min)     NTFY_PRIORITY="min" ;;
      *)              NTFY_PRIORITY="${ntfyCfg.defaultPriority}" ;;
    esac

    MAX_RETRIES=${toString ntfyCfg.retryAttempts}
    TIMEOUT=${toString ntfyCfg.timeout}
    RETRY_COUNT=0
    SUCCESS=false

    while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
      HTTP_CODE=$(${pkgs.curl}/bin/curl -s -w "%{http_code}" -o /dev/null \
        --max-time "$TIMEOUT" \
        -H "Title: ''${TITLE:-Notification}" \
        -H "Priority: $NTFY_PRIORITY" \
        -H "Markdown: no" \
        -d "''${MESSAGE:-}" \
        "$TOPIC_URL" || echo "000")

      if [ "$HTTP_CODE" = "200" ]; then
        echo "ntfy notification sent successfully (HTTP $HTTP_CODE)"
        SUCCESS=true
        break
      fi

      RETRY_COUNT=$((RETRY_COUNT + 1))
      if [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; then
        echo "ntfy notification failed (HTTP $HTTP_CODE), retrying ($RETRY_COUNT/$MAX_RETRIES)..." >&2
        sleep 2
      else
        echo "ntfy notification failed after $MAX_RETRIES attempts (HTTP $HTTP_CODE)" >&2
      fi
    done

    [ "$SUCCESS" = "true" ] || return 1
    return 0
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

    modules.notifications.backends.ntfy = {
      # ntfy topics here are unauthenticated URLs; no credentials to load.
      deliver = deliverScript;
    };

    # The pre-defined notify-ntfy-{backup-success,backup-failure,service-failure,
    # boot,disk-alert} services that used to live here have been removed. They
    # referenced templates that do not exist (backup-success, backup-failure,
    # service-failure, boot-notification, disk-alert) and an option that does
    # not exist (disk-alert.threshold), so enabling this backend at all would
    # have failed evaluation. They predate the template system and are
    # superseded by it: any of those notifications is now a template plus a
    # notify@ dispatch, delivered through the shared drain.
  };
}
