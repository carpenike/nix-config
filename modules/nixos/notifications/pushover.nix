{ lib
, pkgs
, config
, ...
}:
let
  cfg = config.modules.notifications;
  pushoverCfg = cfg.pushover;

  # Pushover's own hard limits. Exceeding either is a 4xx, which used to mean
  # three failed retries and a dropped notification - so the long ones (a body
  # carrying ten lines of journal output, say) were exactly the ones most
  # likely never to arrive. Truncate instead.
  titleLimit = 250;
  messageLimit = 1024;

  # Delivery script. Reads TITLE, MESSAGE and PRIORITY from the environment
  # rather than baking them in at build time.
  #
  # The previous version took the priority as a Nix argument and its only
  # caller passed the *string* "$PRIORITY", so the build-time lookup missed,
  # defaulted to 0, and then emitted `PRIORITY="0"` - clobbering the value read
  # from the payload. Every notification went out at normal priority, including
  # the ones registered as emergency.
  deliverScript = ''
    set -uo pipefail

    # Read tokens from systemd credentials
    PUSHOVER_TOKEN=$(${pkgs.systemd}/bin/systemd-creds cat PUSHOVER_TOKEN) || return 1
    PUSHOVER_USER=$(${pkgs.systemd}/bin/systemd-creds cat PUSHOVER_USER_KEY) || return 1

    # Map the template priority vocabulary onto Pushover's integers, at
    # runtime, because the priority is only known from the payload.
    case "''${PRIORITY:-normal}" in
      emergency|urgent) PUSHOVER_PRIORITY=2 ;;
      high)             PUSHOVER_PRIORITY=1 ;;
      normal|default)   PUSHOVER_PRIORITY=0 ;;
      low)              PUSHOVER_PRIORITY=-1 ;;
      silent|lowest)    PUSHOVER_PRIORITY=-2 ;;
      -2|-1|0|1|2)      PUSHOVER_PRIORITY="$PRIORITY" ;;
      *)                PUSHOVER_PRIORITY=${toString pushoverCfg.defaultPriority} ;;
    esac

    PUSHOVER_TITLE=$(printf '%s' "''${TITLE:-Notification}" | head -c ${toString titleLimit})
    PUSHOVER_MESSAGE=$(printf '%s' "''${MESSAGE:-}" | head -c ${toString messageLimit})
    [ -n "$PUSHOVER_MESSAGE" ] || PUSHOVER_MESSAGE="(no message body)"

    # Pushover rejects priority 2 unless retry/expire accompany it.
    EXTRA_ARGS=()
    if [ "$PUSHOVER_PRIORITY" = "2" ]; then
      EXTRA_ARGS+=(--data-urlencode "retry=60" --data-urlencode "expire=3600")
    fi

    RESPONSE_FILE=$(mktemp)
    MAX_RETRIES=${toString pushoverCfg.retryAttempts}
    TIMEOUT=${toString pushoverCfg.timeout}
    RETRY_COUNT=0
    SUCCESS=false

    while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
      HTTP_CODE=$(${pkgs.curl}/bin/curl -s -w "%{http_code}" -o "$RESPONSE_FILE" \
        --max-time "$TIMEOUT" \
        --data-urlencode "token=$PUSHOVER_TOKEN" \
        --data-urlencode "user=$PUSHOVER_USER" \
        --data-urlencode "title=$PUSHOVER_TITLE" \
        --data-urlencode "message=$PUSHOVER_MESSAGE" \
        --data-urlencode "priority=$PUSHOVER_PRIORITY" \
        ${lib.optionalString pushoverCfg.enableHtml ''--data-urlencode "html=1"''} \
        ${lib.optionalString (pushoverCfg.defaultDevice != null)
          ''--data-urlencode "device=${pushoverCfg.defaultDevice}"''} \
        "''${EXTRA_ARGS[@]}" \
        "https://api.pushover.net/1/messages.json" || echo "000")

      if [ "$HTTP_CODE" = "200" ]; then
        echo "Pushover notification sent successfully (HTTP $HTTP_CODE)"
        SUCCESS=true
        break
      fi

      RETRY_COUNT=$((RETRY_COUNT + 1))
      if [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; then
        echo "Pushover notification failed (HTTP $HTTP_CODE), retrying ($RETRY_COUNT/$MAX_RETRIES)..." >&2
        sleep 2
      else
        echo "Pushover notification failed after $MAX_RETRIES attempts (HTTP $HTTP_CODE)" >&2
        [ -f "$RESPONSE_FILE" ] && echo "Response: $(cat "$RESPONSE_FILE")" >&2
      fi
    done

    rm -f "$RESPONSE_FILE"
    [ "$SUCCESS" = "true" ] || return 1
    return 0
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

    # Register Pushover as a delivery backend. The drain routes to whatever
    # is registered here, so the payload's `backend` field is all it needs -
    # no per-backend knowledge in the drain, and adding a backend does not
    # mean touching it.
    modules.notifications.backends.pushover = {
      credentials = [
        "PUSHOVER_TOKEN:${pushoverCfg.tokenFile}"
        "PUSHOVER_USER_KEY:${pushoverCfg.userKeyFile}"
      ];
      deliver = deliverScript;
    };

    # The per-instance path unit template that used to live here is gone, along
    # with the notify-pushover@ service it triggered. Its contract - "instances
    # are activated by their callers" - could not be satisfied: callers name
    # instances at failure time (template:%n), so there was nothing to declare
    # at build time. notify-drain.path watches the directory instead.

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

      # Pass %i as command-line argument so systemd expands it
      scriptArgs = "%i";

      script = ''
        # Receive instance string as $1
        INSTANCE_NAME="$1"

        deliver_pushover() {
        ${deliverScript}
        }

        TITLE="⚠️ Service Failed"
        MESSAGE="<b>Service $INSTANCE_NAME failed</b><small>
        <b>Host:</b> ${cfg.hostname}
        <b>Time:</b> $(${pkgs.coreutils}/bin/date '+%b %-d, %-I:%M %p %Z')

        <b>Status:</b>
        $(${pkgs.systemd}/bin/systemctl status "$INSTANCE_NAME" --no-pager -l || true)</small>"
        PRIORITY="high"
        export TITLE MESSAGE PRIORITY

        deliver_pushover
      '';
    };
  };
}
