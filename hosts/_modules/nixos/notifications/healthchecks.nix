{ lib
, pkgs
, config
, ...
}:
let
  cfg = config.modules.notifications;
  hcCfg = cfg.healthchecks;

  # Script to ping Healthchecks.io
  mkHealthchecksPing =
    { status ? "success"
    , # success, fail, start
      message ? null
    ,
    }: ''
      set -euo pipefail

      # Read UUID from file
      if [ -f "${toString hcCfg.uuidFile}" ]; then
        HC_UUID=$(cat "${toString hcCfg.uuidFile}")
      else
        echo "ERROR: Healthchecks.io UUID file not found: ${toString hcCfg.uuidFile}" >&2
        exit 1
      fi

      # Determine endpoint
      case "${status}" in
        success)
          ENDPOINT="${hcCfg.baseUrl}/$HC_UUID"
          ;;
        fail)
          ENDPOINT="${hcCfg.baseUrl}/$HC_UUID/fail"
          ;;
        start)
          ENDPOINT="${hcCfg.baseUrl}/$HC_UUID/start"
          ;;
        *)
          echo "ERROR: Invalid status: ${status}" >&2
          exit 1
          ;;
      esac

      # Send ping with retries
      MAX_RETRIES=${toString hcCfg.retryAttempts}
      TIMEOUT=${toString hcCfg.timeout}
      RETRY_COUNT=0
      SUCCESS=false

      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if [ -n "${lib.optionalString (message != null) "yes"}" ]; then
          HTTP_CODE=$(${pkgs.curl}/bin/curl -fsS -w "%{http_code}" -o /dev/null \
            --max-time "$TIMEOUT" \
            --data-raw "${if message != null then message else ""}" \
            "$ENDPOINT" || echo "000")
        else
          HTTP_CODE=$(${pkgs.curl}/bin/curl -fsS -w "%{http_code}" -o /dev/null \
            --max-time "$TIMEOUT" \
            "$ENDPOINT" || echo "000")
        fi

        if [ "$HTTP_CODE" = "200" ]; then
          echo "Healthchecks.io ping sent successfully (HTTP $HTTP_CODE)"
          SUCCESS=true
          break
        else
          RETRY_COUNT=$((RETRY_COUNT + 1))
          if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo "Healthchecks.io ping failed (HTTP $HTTP_CODE), retrying ($RETRY_COUNT/$MAX_RETRIES)..." >&2
            sleep 2
          else
            echo "Healthchecks.io ping failed after $MAX_RETRIES attempts (HTTP $HTTP_CODE)" >&2
          fi
        fi
      done

      if [ "$SUCCESS" = "false" ]; then
        exit 1
      fi
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

    # Generic ping service template
    systemd.services."healthcheck-ping@" = {
      description = "Ping Healthchecks.io for %i";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      # Service receives parameters via environment variables:
      # HC_STATUS (success/fail/start), HC_MESSAGE
      script = ''
        STATUS="''${HC_STATUS:-success}"
        MESSAGE="''${HC_MESSAGE:-%i check from ${cfg.hostname}}"

        ${mkHealthchecksPing {
          status = "$STATUS";
          message = "$MESSAGE";
        }}
      '';
    };

    # Backup success ping
    systemd.services."healthcheck-backup-success@" = lib.mkIf cfg.templates.backup-success.enable {
      description = "Healthchecks.io success ping for backup %i";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = mkHealthchecksPing {
        status = "success";
        message = "Backup completed successfully for %i on ${cfg.hostname}";
      };
    };

    # Backup failure ping
    systemd.services."healthcheck-backup-failure@" = lib.mkIf cfg.templates.backup-failure.enable {
      description = "Healthchecks.io failure ping for backup %i";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = mkHealthchecksPing {
        status = "fail";
        message = "Backup failed for %i on ${cfg.hostname}";
      };
    };

    # Backup start ping (useful for long-running backups)
    systemd.services."healthcheck-backup-start@" = lib.mkIf cfg.templates.backup-success.enable {
      description = "Healthchecks.io start ping for backup %i";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = mkHealthchecksPing {
        status = "start";
        message = "Backup starting for %i on ${cfg.hostname}";
      };
    };
  };
}
