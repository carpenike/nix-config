# Pure helper functions for storage operations
# This is NOT a NixOS module - it's a pure function library
# Import with: storageHelpers = import ./helpers-lib.nix { inherit pkgs lib; };

{ pkgs, lib }:
{
  /*
    Generates a systemd service to pre-seed a service's data directory.

    This service runs before the main application service starts. It checks if the
    data directory is empty. If it is, it attempts to restore data from a ZFS
    replication source, local ZFS snapshots, or a Restic backup repository.

    Arguments:
      - serviceName: (string) The name of the service (e.g., "sonarr").
      - dataset: (string) The full ZFS dataset path (e.g., "tank/services/sonarr").
      - mountpoint: (string) The absolute path to the data directory.
      - mainServiceUnit: (string) The name of the main service unit to start after this one.
      - replicationCfg: (attrset or null) Configuration for ZFS receive restore.
          - targetHost: (string) Remote host to pull from.
          - targetDataset: (string) ZFS dataset on the remote host.
          - sshUser: (string) SSH user for the remote host (default: "root").
          - sshKeyPath: (string) Path to the SSH private key.
      - resticRepoUrl: (string) The Restic repository URL for restore.
      - resticPasswordFile: (string) Path to the Restic password file.
      - resticEnvironmentFile: (string or null) Path to environment file for Restic (optional).
      - resticPaths: (list of strings) Paths to restore from the Restic backup.
      - hasCentralizedNotifications: (bool) Whether centralized notifications are enabled.
      - timeoutSec: (int) Timeout for the preseed operation (default: 1800).
      - owner: (string) User to own the restored files (default: "root").
      - group: (string) Group to own the restored files (default: "root").
  */
  mkPreseedService = {
    serviceName,
    dataset,
    mountpoint,
    mainServiceUnit,
    replicationCfg ? null,
    datasetProperties ? { recordsize = "128K"; compression = "lz4"; },  # Defaults for when not specified
    resticRepoUrl,
    resticPasswordFile,
    resticEnvironmentFile ? null,
    resticPaths,
    restoreMethods ? [ "syncoid" "local" "restic" ],  # Configurable restore order (default maintains current behavior)
    hasCentralizedNotifications ? false,
    timeoutSec ? 1800,
    owner ? "root",
    group ? "root"
  }:
  let
    hasReplication = replicationCfg != null && (replicationCfg.targetHost or null) != null;

    # Validate and normalize restore methods list
    validMethods = [ "syncoid" "local" "restic" ];
    orderRaw = lib.unique restoreMethods;
    order = builtins.filter (m: lib.elem m validMethods) orderRaw;

    # Check which methods are enabled
    useSyncoid = hasReplication && (lib.elem "syncoid" order);
    useLocal = lib.elem "local" order;
    useRestic = lib.elem "restic" order;

    # Helper to trigger a notification
    notify = template: message: ''
      ${lib.optionalString hasCentralizedNotifications ''
        echo "${message}"
        export NOTIFY_MESSAGE="${lib.escapeShellArg message}"
        # The dispatcher service uses the instance info as the serviceName
        ${pkgs.systemd}/bin/systemctl start "notify@${template}:${serviceName}.service"
      ''}
    '';
  in
  {
    systemd.services."preseed-${serviceName}" = {
      description = "Pre-seed data for ${serviceName} service";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];  # Declare dependency to avoid warning
      after = [ "network-online.target" "zfs-import.target" "zfs-mount.service" ];
      before = [ mainServiceUnit ];

      path = with pkgs; [ zfs coreutils gnugrep gawk restic systemd openssh sanoid ];

      serviceConfig = {
        Type = "oneshot";
        User = "root"; # Root is required for zfs rollback and chown
        TimeoutStartSec = timeoutSec;
      };

      script = ''
        set -euo pipefail

        # Use absolute paths from Nix store to ensure binaries are available
        ZFS="${pkgs.zfs}/bin/zfs"
        SYNCOID="${pkgs.sanoid}/bin/syncoid"
        NUMFMT="${pkgs.coreutils}/bin/numfmt"
        ${lib.optionalString hasReplication ''DATASET_DESTROYED=false''}


        # Helper function to ensure dataset is mounted before file operations
        ensure_mounted() {
          if "$ZFS" list "${dataset}" &>/dev/null; then
            mkdir -p "${mountpoint}"
            "$ZFS" set mountpoint="${mountpoint}" "${dataset}" 2>/dev/null || true
            "$ZFS" mount "${dataset}" 2>/dev/null || true
          fi
        }

        # Helper function to clean up old protective snapshots (keep last 2)
        cleanup_protective_snapshots() {
          "$ZFS" list -H -t snapshot -o name -s creation -r "${dataset}" 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep '@preseed_protect_' | \
            ${pkgs.coreutils}/bin/head -n -2 | \
            while read -r snap; do
              "$ZFS" destroy "$snap" 2>/dev/null || true
            done
        }

        # Restore method: ZFS syncoid replication (if configured)
        ${lib.optionalString hasReplication ''
        restore_syncoid() {
          echo "Attempting ZFS receive via syncoid from ${replicationCfg.targetHost}:${replicationCfg.targetDataset}..."

          # Track if we destroy the dataset so we can recreate it if all restores fail
          DATASET_DESTROYED=false

          # Check if target dataset exists but is empty (created by config but never populated)
          # Syncoid requires target to NOT exist for initial replication
          if "$ZFS" list "${dataset}" &>/dev/null; then
            # Use headerless output for robust snapshot counting
            SNAPSHOT_COUNT=$("$ZFS" list -H -t snapshot -r "${dataset}" 2>/dev/null | ${pkgs.coreutils}/bin/wc -l || echo "0")
            DATASET_USED=$("$ZFS" get -H -o value used "${dataset}" 2>/dev/null || echo "unknown")
            DATASET_USED_BYTES=$("$ZFS" get -H -o value -p used "${dataset}" 2>/dev/null || echo "0")
            # Use logicalreferenced to account for compression/dedup (fallback to used)
            DATASET_LOGICAL_BYTES=$("$ZFS" get -H -o value -p logicalreferenced "${dataset}" 2>/dev/null || echo "0")
            if ! echo "$DATASET_LOGICAL_BYTES" | ${pkgs.gnugrep}/bin/grep -qE '^[0-9]+$'; then
              DATASET_LOGICAL_BYTES="$DATASET_USED_BYTES"
            fi
            FRIENDLY_LOGICAL=$("$NUMFMT" --to=iec "$DATASET_LOGICAL_BYTES" 2>/dev/null || echo "$DATASET_LOGICAL_BYTES")
            echo "Target dataset ${dataset} exists with $SNAPSHOT_COUNT snapshots (used: $DATASET_USED, logical: $FRIENDLY_LOGICAL)"

            # Only destroy if dataset has no snapshots AND is essentially empty (< 1MB logical)
            # SAFETY: Use conservative 1MB threshold on LOGICAL size to protect against race conditions where:
            # - New service creates data but no snapshot exists yet (first sanoid run is hourly)
            # - Service restarts before first snapshot, preseed runs again
            # - Compression/dedup makes physical size misleading (10MB data might show as 1MB used)
            # Original syncoid check was 64MB physical, we use 1MB logical for maximum safety
            if [ "$SNAPSHOT_COUNT" -eq 0 ] && [ "$DATASET_LOGICAL_BYTES" -lt 1048576 ]; then
              # Double-check immediately before destroy to avoid racing with sanoid
              SNAPSHOT_COUNT=$("$ZFS" list -H -t snapshot -r "${dataset}" 2>/dev/null | ${pkgs.coreutils}/bin/wc -l || echo "0")
              RESUME_TOKEN=$("$ZFS" get -H -o value receive_resume_token "${dataset}" 2>/dev/null || echo "-")

              if [ "$SNAPSHOT_COUNT" -eq 0 ] && [ "$RESUME_TOKEN" = "-" ]; then
                echo "Target dataset still has no snapshots and < 1MB logical data. Destroying for initial replication..."
                "$ZFS" destroy -r "${dataset}"
                DATASET_DESTROYED=true
              else
                echo "Refusing to destroy: snapshots now present ($SNAPSHOT_COUNT) or receive in progress (token=$RESUME_TOKEN)."
              fi
            elif [ "$SNAPSHOT_COUNT" -eq 0 ]; then
              echo "WARNING: Target dataset has no snapshots but is $DATASET_USED in size ($(numfmt --to=iec $DATASET_LOGICAL_BYTES 2>/dev/null || echo $DATASET_LOGICAL_BYTES) logical)."
              echo "Refusing to destroy - may contain user data."
              echo "If this is a fresh deployment and you want to restore from backup, manually run: zfs destroy -r ${dataset}"
            fi
          fi

          # Use syncoid for robust replication with resume support and better error handling
          if "$SYNCOID" \
            --no-sync-snap \
            --no-privilege-elevation \
            --sshkey=${lib.escapeShellArg replicationCfg.sshKeyPath} \
            --sshoption=ConnectTimeout=10 \
            --sshoption=ServerAliveInterval=10 \
            --sshoption=ServerAliveCountMax=3 \
            --sshoption=StrictHostKeyChecking=accept-new \
            --sendoptions=${lib.escapeShellArg replicationCfg.sendOptions} \
            --recvoptions=${lib.escapeShellArg replicationCfg.recvOptions} \
            ${lib.escapeShellArg (replicationCfg.sshUser + "@" + replicationCfg.targetHost + ":" + replicationCfg.targetDataset)} \
            ${lib.escapeShellArg dataset}; then
            echo "Syncoid replication successful."

            # CRITICAL: Dataset may be unmounted due to recvOptions='u'.
            # Explicitly set mountpoint and mount before chown.
            echo "Ensuring dataset is mounted at ${mountpoint}..."
            mkdir -p "${mountpoint}"
            "$ZFS" set mountpoint="${mountpoint}" "${dataset}"

            # NOTE: ZFS send/receive may not preserve all properties depending on send flags.
            # If source replication doesn't use -p flag, properties will be wrong.
            # These are set explicitly to ensure declarative config is honored.
            # TODO: Remove these if/when all replications use sendOptions="wp"
            echo "Resetting dataset properties to match declarative config..."
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (prop: value:
              ''"$ZFS" set ${lib.escapeShellArg prop}=${lib.escapeShellArg value} "${dataset}" || echo "Failed to set ${lib.escapeShellArg prop}"''
            ) datasetProperties)}

            "$ZFS" mount "${dataset}" || echo "Dataset already mounted or mount failed (may already be mounted)"

            chown -R ${owner}:${group} "${mountpoint}"

            # Take protective snapshot if none exist to close vulnerability window
            SNAPSHOT_COUNT=$("$ZFS" list -H -t snapshot -r "${dataset}" 2>/dev/null | ${pkgs.coreutils}/bin/wc -l || echo "0")
            if [ "$SNAPSHOT_COUNT" -eq 0 ]; then
              echo "Taking protective snapshot after successful restore..."
              "$ZFS" snapshot "${dataset}@preseed_protect_$(date +%s)" || true
              cleanup_protective_snapshots
            fi

            ${notify "preseed-success" "Successfully restored ${serviceName} data from ZFS replication source ${replicationCfg.targetHost}."}
            return 0
          else
            echo "Syncoid replication failed. Proceeding to next restore method."
            return 1
          fi
        }
        ''}

        ${lib.optionalString (!hasReplication) ''
        restore_syncoid() {
          echo "Syncoid restore not available (no replication config)."
          return 1
        }
        ''}

        # Restore method: Local ZFS snapshot rollback
        restore_local() {
          # Prefer sanoid-created snapshots, but fall back to any snapshot if none exist
          LATEST_SNAPSHOT=$("$ZFS" list -H -t snapshot -o name -s creation -r "${dataset}" | ${pkgs.gnugrep}/bin/grep '@sanoid_' | ${pkgs.coreutils}/bin/tail -n 1 || true)

          # If no sanoid snapshots, try any snapshot
          if [ -z "$LATEST_SNAPSHOT" ]; then
            LATEST_SNAPSHOT=$("$ZFS" list -H -t snapshot -o name -s creation -r "${dataset}" | ${pkgs.coreutils}/bin/tail -n 1 || true)
          fi

          if [ -n "$LATEST_SNAPSHOT" ]; then
            echo "Found latest ZFS snapshot: $LATEST_SNAPSHOT"
            echo "Attempting to roll back..."

            # Ensure dataset is mounted before rollback
            ensure_mounted

            # Hold snapshot to prevent sanoid from pruning during rollback
            "$ZFS" hold preseed "$LATEST_SNAPSHOT" 2>/dev/null || true

            if "$ZFS" rollback -r "$LATEST_SNAPSHOT"; then
              echo "ZFS rollback successful."

              # Release the hold
              "$ZFS" release preseed "$LATEST_SNAPSHOT" 2>/dev/null || true

              # Ensure correct ownership after rollback
              chown -R ${owner}:${group} "${mountpoint}"

              # Take protective snapshot if none exist (shouldn't happen after rollback, but safety first)
              SNAPSHOT_COUNT=$("$ZFS" list -H -t snapshot -r "${dataset}" 2>/dev/null | ${pkgs.coreutils}/bin/wc -l || echo "0")
              if [ "$SNAPSHOT_COUNT" -eq 0 ]; then
                echo "Taking protective snapshot after successful rollback..."
                "$ZFS" snapshot "${dataset}@preseed_protect_$(date +%s)" || true
                cleanup_protective_snapshots
              fi

              ${notify "preseed-success" "Successfully restored ${serviceName} data from ZFS snapshot $LATEST_SNAPSHOT."}
              return 0
            else
              # Release hold on failure
              "$ZFS" release preseed "$LATEST_SNAPSHOT" 2>/dev/null || true
              echo "ZFS rollback failed. Proceeding to next restore method."
              return 1
            fi
          else
            echo "No suitable ZFS snapshots found for ${dataset}."
            return 1
          fi
        }

        # Restore method: Restic backup restore (with retry)
        restore_restic() {
          echo "Attempting Restic restore from repository '${resticRepoUrl}'..."

          ${lib.optionalString (resticEnvironmentFile != null) ''
            # Source environment file for restic credentials
            set -a
            . "${resticEnvironmentFile}"
            set +a
          ''}

          # Ensure dataset exists and is mounted before Restic restore
          # If syncoid destroyed the dataset, we need to recreate it
          if ! "$ZFS" list "${dataset}" &>/dev/null; then
            echo "Dataset ${dataset} does not exist. Creating for Restic restore..."
            mkdir -p "${mountpoint}"
            "$ZFS" create -o mountpoint="${mountpoint}" ${lib.concatStringsSep " " (lib.mapAttrsToList (prop: value: "-o ${prop}=${lib.escapeShellArg value}") datasetProperties)} "${dataset}"
          fi
          ensure_mounted

          RESTIC_ARGS=(
            -r "${resticRepoUrl}"
            --password-file "${resticPasswordFile}"
            restore latest
            --target "${mountpoint}"
          )
          # Append --path arguments as discrete array elements to avoid word-splitting issues
          ${lib.concatMapStringsSep "\n" (p: ''
            RESTIC_ARGS+=( --path ${lib.escapeShellArg p} )
          '') resticPaths}

          if restic "''${RESTIC_ARGS[@]}"; then
            echo "Restic restore successful."
            # Ensure correct ownership after restore
            chown -R ${owner}:${group} "${mountpoint}"

            # Take protective snapshot if none exist to close vulnerability window
            SNAPSHOT_COUNT=$("$ZFS" list -H -t snapshot -r "${dataset}" 2>/dev/null | ${pkgs.coreutils}/bin/wc -l || echo "0")
            if [ "$SNAPSHOT_COUNT" -eq 0 ]; then
              echo "Taking protective snapshot after successful Restic restore..."
              "$ZFS" snapshot "${dataset}@preseed_protect_$(date +%s)" || true
              cleanup_protective_snapshots
            fi

            ${notify "preseed-success" "Successfully restored ${serviceName} data from Restic repository ${resticRepoUrl}."}
            return 0
          else
            echo "Restic restore failed on first attempt. Retrying once after transient failure..."
            sleep 5
            if restic "''${RESTIC_ARGS[@]}"; then
              echo "Restic restore successful on retry."
              chown -R ${owner}:${group} "${mountpoint}"

              # Take protective snapshot if none exist to close vulnerability window
              SNAPSHOT_COUNT=$("$ZFS" list -H -t snapshot -r "${dataset}" 2>/dev/null | ${pkgs.coreutils}/bin/wc -l || echo "0")
              if [ "$SNAPSHOT_COUNT" -eq 0 ]; then
                echo "Taking protective snapshot after successful Restic restore (retry)..."
                "$ZFS" snapshot "${dataset}@preseed_protect_$(date +%s)" || true
                cleanup_protective_snapshots
              fi

              ${notify "preseed-success" "Successfully restored ${serviceName} data from Restic repository ${resticRepoUrl} (retry)."}
              return 0
            else
              echo "Restic restore failed after retry."
              return 1
            fi
          fi
        }

        echo "Starting preseed check for ${serviceName} at ${mountpoint}..."

        # Step 1: Check if data directory is empty AND verify dataset state
        # Using `ls -A` to account for hidden files.
        if [ -n "$(ls -A "${mountpoint}" 2>/dev/null)" ]; then
          # If dataset exists and has zero snapshots, take a protective one to close vulnerability window
          if "$ZFS" list "${dataset}" &>/dev/null; then
            SNAPSHOT_COUNT=$("$ZFS" list -H -t snapshot -r "${dataset}" 2>/dev/null | ${pkgs.coreutils}/bin/wc -l || echo "0")
            if [ "$SNAPSHOT_COUNT" -eq 0 ]; then
              echo "Dataset has data but no snapshots. Taking protective snapshot..."
              "$ZFS" snapshot "${dataset}@preseed_protect_$(date +%s)" || true
              cleanup_protective_snapshots
            fi
          fi
          ${notify "preseed-skipped" "Data for ${serviceName} already exists. Skipping restore."}
          exit 0
        fi

        # Additional safety: If dataset exists and is mounted with ANY data, skip restore
        # This protects against race conditions where mountpoint appears empty but dataset has data
        if "$ZFS" list "${dataset}" &>/dev/null; then
          DATASET_USED_BYTES=$("$ZFS" get -H -o value -p used "${dataset}" 2>/dev/null || echo "0")
          # Use logicalreferenced to account for compression/dedup (fallback to used)
          DATASET_LOGICAL_BYTES=$("$ZFS" get -H -o value -p logicalreferenced "${dataset}" 2>/dev/null || echo "0")
          # Fallback if logicalreferenced isn't supported or non-numeric
          if ! echo "$DATASET_LOGICAL_BYTES" | ${pkgs.gnugrep}/bin/grep -qE '^[0-9]+$'; then
            DATASET_LOGICAL_BYTES="$DATASET_USED_BYTES"
          fi
          IS_MOUNTED=$("$ZFS" get -H -o value mounted "${dataset}" 2>/dev/null || echo "no")

          # If dataset is mounted and has ANY logical data beyond ZFS metadata (>192KB), skip restore
          # 192KB threshold accounts for empty ZFS filesystem overhead
          # Using logicalreferenced prevents compression from hiding real data size
          if [ "$IS_MOUNTED" = "yes" ] && [ "$DATASET_LOGICAL_BYTES" -gt 196608 ]; then
            echo "Dataset ${dataset} is mounted with $DATASET_LOGICAL_BYTES logical bytes. Skipping restore for safety."
            FRIENDLY_SIZE=$("$NUMFMT" --to=iec "$DATASET_LOGICAL_BYTES" 2>/dev/null || echo "$DATASET_LOGICAL_BYTES bytes")
            ${notify "preseed-skipped" "Dataset ${serviceName} exists with data ($FRIENDLY_SIZE logical). Skipping restore."}
            exit 0
          fi
        fi

        echo "Data directory is empty. Attempting restore..."

        # Build restore method sequence from Nix-normalized list
        ORDER=()
        ${lib.concatMapStringsSep "\n" (m: ''ORDER+=(${lib.escapeShellArg m})'') order}

        # Execute restore methods in requested order until one succeeds
        for method in "''${ORDER[@]}"; do
          case "$method" in
            syncoid)
              if restore_syncoid; then exit 0; fi
              ;;
            local)
              if restore_local; then exit 0; fi
              ;;
            restic)
              if restore_restic; then exit 0; fi
              ;;
            *)
              echo "Unknown restore method '$method' - skipping."
              ;;
          esac
        done

        # Step 5: All restore methods failed
        ${notify "preseed-failure" "All restore attempts for ${serviceName} failed. Service will start with an empty data directory."}
        echo "Allowing ${serviceName} to start with an empty data directory."

        # If we destroyed the dataset earlier (for syncoid initial replication) but all restores failed,
        # we need to recreate it so the service has a filesystem to write to.
        ${lib.optionalString hasReplication ''
          if [ "$DATASET_DESTROYED" = "true" ] && ! "$ZFS" list "${dataset}" &>/dev/null; then
            echo "Dataset was destroyed but restores failed. Recreating empty dataset with proper properties..."
            mkdir -p "${mountpoint}"
            "$ZFS" create \
              -o mountpoint="${mountpoint}" \
              ${lib.concatStringsSep " \\\n              " (lib.mapAttrsToList (prop: value:
                "-o ${prop}=${lib.escapeShellArg value}"
              ) datasetProperties)} \
              "${dataset}"
            "$ZFS" mount "${dataset}" || echo "Dataset already mounted"
            chown -R ${owner}:${group} "${mountpoint}"
            echo "Empty dataset created. Service can now start fresh."
          fi
        ''}

        exit 0 # Exit successfully to not block service start
      '';
    };
  };
}
