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
    hasCentralizedNotifications ? false,
    timeoutSec ? 1800,
    owner ? "root",
    group ? "root"
  }:
  let
    hasReplication = replicationCfg != null && (replicationCfg.targetHost or null) != null;

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

        # Use system ZFS and syncoid binaries to avoid userland/kernel version mismatches
        ZFS="/run/current-system/sw/bin/zfs"
        SYNCOID="/run/current-system/sw/bin/syncoid"

        echo "Starting preseed check for ${serviceName} at ${mountpoint}..."

        # Step 1: Check if data directory is empty.
        # Using `ls -A` to account for hidden files.
        if [ -n "$(ls -A "${mountpoint}" 2>/dev/null)" ]; then
          ${notify "preseed-skipped" "Data for ${serviceName} already exists. Skipping restore."}
          exit 0
        fi

        echo "Data directory is empty. Attempting restore..."

        # Step 2: Attempt ZFS receive from replication target using syncoid (fastest remote)
        ${lib.optionalString hasReplication ''
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
            echo "Target dataset ${dataset} exists with $SNAPSHOT_COUNT snapshots (used: $DATASET_USED)"

            # Only destroy if dataset has no snapshots AND is very small (< 64MB)
            # This mirrors syncoid's own safety check
            if [ "$SNAPSHOT_COUNT" -eq 0 ] && [ "$DATASET_USED_BYTES" -lt 67108864 ]; then
              echo "Target dataset has no snapshots and < 64MB used. Destroying for initial replication..."
              "$ZFS" destroy -r "${dataset}"
              DATASET_DESTROYED=true
            elif [ "$SNAPSHOT_COUNT" -eq 0 ]; then
              echo "WARNING: Target dataset has no snapshots but is $DATASET_USED in size. Skipping destroy for safety."
            fi
          fi          # Use syncoid for robust replication with resume support and better error handling
          if "$SYNCOID" \
            --no-sync-snap \
            --no-privilege-elevation \
            --sshkey="${lib.escapeShellArg replicationCfg.sshKeyPath}" \
            --sshoption=ConnectTimeout=10 \
            --sshoption=ServerAliveInterval=10 \
            --sshoption=ServerAliveCountMax=3 \
            --sshoption=StrictHostKeyChecking=accept-new \
            --sendoptions="${lib.escapeShellArg replicationCfg.sendOptions}" \
            --recvoptions="${lib.escapeShellArg replicationCfg.recvOptions}" \
            "${lib.escapeShellArg replicationCfg.sshUser}@${lib.escapeShellArg replicationCfg.targetHost}:${lib.escapeShellArg replicationCfg.targetDataset}" \
            "${lib.escapeShellArg dataset}"; then
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
              ''"$ZFS" set ${prop}=${lib.escapeShellArg value} "${dataset}" || echo "Failed to set ${prop}"''
            ) datasetProperties)}

            "$ZFS" mount "${dataset}" || echo "Dataset already mounted or mount failed (may already be mounted)"

            chown -R ${owner}:${group} "${mountpoint}"
            ${notify "preseed-success" "Successfully restored ${serviceName} data from ZFS replication source ${replicationCfg.targetHost}."}
            exit 0
          else
            echo "Syncoid replication failed. Proceeding to next restore method."
          fi
        ''}

        # Step 3: Attempt ZFS snapshot rollback (fastest local)
        # Find the latest sanoid-created snapshot for this dataset.
        LATEST_SNAPSHOT=$("$ZFS" list -H -t snapshot -o name -s creation -r "${dataset}" | ${pkgs.gnugrep}/bin/grep '@sanoid_' | ${pkgs.gawk}/bin/tail -n 1 || true)

        if [ -n "$LATEST_SNAPSHOT" ]; then
          echo "Found latest ZFS snapshot: $LATEST_SNAPSHOT"
          echo "Attempting to roll back..."
          if "$ZFS" rollback -r "$LATEST_SNAPSHOT"; then
            echo "ZFS rollback successful."
            # Ensure correct ownership after rollback
            chown -R ${owner}:${group} "${mountpoint}"
            ${notify "preseed-success" "Successfully restored ${serviceName} data from ZFS snapshot $LATEST_SNAPSHOT."}
            exit 0
          else
            echo "ZFS rollback failed. Proceeding to next restore method."
          fi
        else
          echo "No suitable ZFS snapshots found for ${dataset}."
        fi

        # Step 4: Attempt Restic restore (slower, from remote)
        echo "Attempting Restic restore from repository '${resticRepoUrl}'..."

        ${lib.optionalString (resticEnvironmentFile != null) ''
          # Source environment file for restic credentials
          set -a
          . "${resticEnvironmentFile}"
          set +a
        ''}

        # Ensure the target directory exists before restore
        mkdir -p "${mountpoint}"

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
          ${notify "preseed-success" "Successfully restored ${serviceName} data from Restic repository ${resticRepoUrl}."}
          exit 0
        else
          echo "Restic restore failed on first attempt. Retrying once after transient failure..."
          sleep 5
          if restic "''${RESTIC_ARGS[@]}"; then
            echo "Restic restore successful on retry."
            chown -R ${owner}:${group} "${mountpoint}"
            ${notify "preseed-success" "Successfully restored ${serviceName} data from Restic repository ${resticRepoUrl} (retry)."}
            exit 0
          else
            echo "Restic restore failed after retry."
          fi
        fi

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
