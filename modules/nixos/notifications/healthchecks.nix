{ lib
, pkgs
, config
, ...
}:
let
  cfg = config.modules.notifications;
  hcCfg = cfg.healthchecks;

  # Delivery script. Reads TITLE, MESSAGE and PRIORITY from the environment.
  #
  # Healthchecks.io has no notion of a message priority - a ping either signals
  # health or failure - so the template priority decides which endpoint is hit.
  deliverScript = ''
    set -uo pipefail

    # Read from a systemd credential rather than the secret path directly:
    # this runs under DynamicUser with ProtectSystem=strict, which cannot be
    # relied on to reach a sops secret.
    HC_UUID=$(${pkgs.systemd}/bin/systemd-creds cat HEALTHCHECKS_UUID) || return 1
    if [ -z "$HC_UUID" ]; then
      echo "[healthchecks] ERROR: UUID credential is empty" >&2
      return 1
    fi

    case "''${PRIORITY:-normal}" in
      emergency|urgent|high) ENDPOINT="${hcCfg.baseUrl}/$HC_UUID/fail" ;;
      *)                     ENDPOINT="${hcCfg.baseUrl}/$HC_UUID" ;;
    esac

    BODY=$(printf '%s\n\n%s' "''${TITLE:-Notification}" "''${MESSAGE:-}")

    MAX_RETRIES=${toString hcCfg.retryAttempts}
    TIMEOUT=${toString hcCfg.timeout}
    RETRY_COUNT=0
    SUCCESS=false

    while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
      HTTP_CODE=$(${pkgs.curl}/bin/curl -sS -w "%{http_code}" -o /dev/null \
        --max-time "$TIMEOUT" \
        --data-raw "$BODY" \
        "$ENDPOINT" || echo "000")

      if [ "$HTTP_CODE" = "200" ]; then
        echo "Healthchecks.io ping sent successfully (HTTP $HTTP_CODE)"
        SUCCESS=true
        break
      fi

      RETRY_COUNT=$((RETRY_COUNT + 1))
      if [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; then
        echo "Healthchecks.io ping failed (HTTP $HTTP_CODE), retrying ($RETRY_COUNT/$MAX_RETRIES)..." >&2
        sleep 2
      else
        echo "Healthchecks.io ping failed after $MAX_RETRIES attempts (HTTP $HTTP_CODE)" >&2
      fi
    done

    [ "$SUCCESS" = "true" ] || return 1
    return 0
  '';
in
{
  config = lib.mkIf (cfg.enable && hcCfg.enable) {
    # Validate configuration (at build time)
    assertions = [
      {
        assertion = hcCfg.uuidFile != null;
        message = "modules.notifications.healthchecks.uuidFile must be set when Healthchecks.io is enabled";
      }
      # Note: We don't check pathExists here because sops secrets won't exist until runtime
    ];

    modules.notifications.backends.healthchecks = {
      credentials = [ "HEALTHCHECKS_UUID:${toString hcCfg.uuidFile}" ];
      deliver = deliverScript;
    };

    # The pre-defined healthcheck-{ping,backup-success,backup-failure,
    # backup-start}@ services that used to live here have been removed. They
    # referenced templates that do not exist (backup-success, backup-failure),
    # so enabling this backend at all would have failed evaluation, and they
    # predate the template system that supersedes them.
  };
}
