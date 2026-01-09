# hosts/forge/services/qui-auto-recheck.nix
#
# Automated recheck and resume for torrents with missingFiles state.
#
# Some cross-seed sources (notably SceneTime) use naming conventions that
# differ from the original release (spaces instead of dots, no extension).
# This causes qBittorrent to show "missing files" even though the content
# exists. Running a recheck resolves this, but torrents stop after recheck
# and need to be resumed.
#
# This timer runs every 15 minutes to:
# 1. Find all torrents in missingFiles state
# 2. Trigger recheck on those torrents
# 3. Wait briefly for recheck to complete
# 4. Resume any torrents that are now in stoppedDL state
#
# Requires: qui API key in SOPS at qui/api-key

{ config, lib, pkgs, ... }:

let
  quiEnabled = config.modules.services.qui.enable or false;
in
{
  config = lib.mkIf quiEnabled {
    # SOPS secret for qui API key
    sops.secrets."qui/api-key" = {
      owner = "root";
      group = "root";
      mode = "0400";
    };

    # Timer runs every 15 minutes
    systemd.timers.qui-auto-recheck = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m"; # Start 5 minutes after boot
        OnUnitActiveSec = "15m"; # Run every 15 minutes
        Unit = "qui-auto-recheck.service";
      };
    };

    systemd.services.qui-auto-recheck = {
      description = "Auto-recheck and resume torrents with missing files";
      after = [ "network-online.target" "podman-qui.service" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        # Systemd hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      path = with pkgs; [ curl jq coreutils ];

      script = ''
        set -euo pipefail

        QUI_URL="http://127.0.0.1:7476"
        API_KEY=$(cat ${config.sops.secrets."qui/api-key".path})
        INSTANCE_ID=1

        # Phase 1: Resume any stopped torrents from previous runs
        # This catches torrents where recheck finished after our previous 30s wait
        # stoppedDL = incomplete (needs cross-file pieces), stoppedUP = complete (ready to seed)
        echo "[$(date -Iseconds)] Checking for stopped torrents to resume (from previous runs)..."

        STOPPED_HASHES=$(curl -sf "$QUI_URL/api/instances/$INSTANCE_ID/torrents" \
          -H "X-API-Key: $API_KEY" | \
          jq -r '.torrents[] | select(.state == "stoppedDL" or .state == "stoppedUP") | .hash' || true)

        if [ -n "$STOPPED_HASHES" ]; then
          STOPPED_ARRAY=$(echo "$STOPPED_HASHES" | jq -R -s 'split("\n") | map(select(length > 0))')
          STOPPED_COUNT=$(echo "$STOPPED_ARRAY" | jq 'length')
          echo "[$(date -Iseconds)] Found $STOPPED_COUNT stopped torrents. Resuming..."

          curl -sf -X POST "$QUI_URL/api/instances/$INSTANCE_ID/torrents/bulk-action" \
            -H "X-API-Key: $API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"action\": \"resume\", \"hashes\": $STOPPED_ARRAY}" > /dev/null

          echo "[$(date -Iseconds)] Resumed $STOPPED_COUNT stopped torrents."
        else
          echo "[$(date -Iseconds)] No stopped torrents found."
        fi

        # Phase 2: Find and recheck torrents with missingFiles state
        echo "[$(date -Iseconds)] Checking for torrents with missing files..."

        MISSING_HASHES=$(curl -sf "$QUI_URL/api/instances/$INSTANCE_ID/torrents" \
          -H "X-API-Key: $API_KEY" | \
          jq -r '.torrents[] | select(.state == "missingFiles") | .hash' || true)

        if [ -z "$MISSING_HASHES" ]; then
          echo "[$(date -Iseconds)] No torrents with missing files found. Done."
          exit 0
        fi

        # Convert to JSON array
        HASH_ARRAY=$(echo "$MISSING_HASHES" | jq -R -s 'split("\n") | map(select(length > 0))')
        COUNT=$(echo "$HASH_ARRAY" | jq 'length')

        echo "[$(date -Iseconds)] Found $COUNT torrents with missing files. Triggering recheck..."

        # Trigger recheck
        curl -sf -X POST "$QUI_URL/api/instances/$INSTANCE_ID/torrents/bulk-action" \
          -H "X-API-Key: $API_KEY" \
          -H "Content-Type: application/json" \
          -d "{\"action\": \"recheck\", \"hashes\": $HASH_ARRAY}" > /dev/null

        echo "[$(date -Iseconds)] Recheck triggered. Waiting 30 seconds for completion..."
        sleep 30

        # Phase 3: Resume any torrents that finished recheck and are now stopped
        # stoppedDL = incomplete (needs cross-file pieces), stoppedUP = complete (ready to seed)
        echo "[$(date -Iseconds)] Checking for stopped torrents to resume..."

        STOPPED_HASHES=$(curl -sf "$QUI_URL/api/instances/$INSTANCE_ID/torrents" \
          -H "X-API-Key: $API_KEY" | \
          jq -r '.torrents[] | select(.state == "stoppedDL" or .state == "stoppedUP") | .hash' || true)

        if [ -z "$STOPPED_HASHES" ]; then
          echo "[$(date -Iseconds)] No stopped torrents found. Done."
          exit 0
        fi

        RESUME_ARRAY=$(echo "$STOPPED_HASHES" | jq -R -s 'split("\n") | map(select(length > 0))')
        RESUME_COUNT=$(echo "$RESUME_ARRAY" | jq 'length')

        echo "[$(date -Iseconds)] Resuming $RESUME_COUNT torrents..."

        curl -sf -X POST "$QUI_URL/api/instances/$INSTANCE_ID/torrents/bulk-action" \
          -H "X-API-Key: $API_KEY" \
          -H "Content-Type: application/json" \
          -d "{\"action\": \"resume\", \"hashes\": $RESUME_ARRAY}" > /dev/null

        echo "[$(date -Iseconds)] Done. Rechecked and resumed $COUNT torrents."
      '';
    };
  };
}
