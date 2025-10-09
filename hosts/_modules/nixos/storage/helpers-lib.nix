# Pure helper functions for storage operations
# This is NOT a NixOS module - it's a pure function library
# Import with: storageHelpers = import ./helpers-lib.nix { inherit pkgs lib; };

{ pkgs, lib }:
{
  /*
    Generates a systemd service to pre-seed a service's data directory.

    This service runs before the main application service starts. It checks if the
    data directory is empty. If it is, it attempts to restore data from ZFS snapshots
    or a Restic backup repository.

    Arguments:
      - serviceName: (string) The name of the service (e.g., "sonarr").
      - dataset: (string) The full ZFS dataset path (e.g., "tank/services/sonarr").
      - mountpoint: (string) The absolute path to the data directory.
      - mainServiceUnit: (string) The name of the main service unit to start after this one.
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
      after = [ "network-online.target" "zfs-import.target" ];
      before = [ mainServiceUnit ];

      path = with pkgs; [ zfs coreutils gnugrep gawk restic systemd ];

      serviceConfig = {
        Type = "oneshot";
        User = "root"; # Root is required for zfs rollback and chown
        TimeoutStartSec = timeoutSec;
      };

      script = ''
        set -euo pipefail

        echo "Starting preseed check for ${serviceName} at ${mountpoint}..."

        # Step 1: Check if data directory is empty.
        # Using `ls -A` to account for hidden files.
        if [ -n "$(ls -A "${mountpoint}" 2>/dev/null)" ]; then
          ${notify "preseed-skipped" "Data for ${serviceName} already exists. Skipping restore."}
          exit 0
        fi

        echo "Data directory is empty. Attempting restore..."

        # Step 2: Attempt ZFS snapshot rollback (fastest)
        # Find the latest sanoid-created snapshot for this dataset.
        LATEST_SNAPSHOT=$(${pkgs.zfs}/bin/zfs list -t snapshot -o name -s creation -r "${dataset}" | ${pkgs.gnugrep}/bin/grep '@sanoid_' | ${pkgs.gawk}/bin/tail -n 1 || true)

        if [ -n "$LATEST_SNAPSHOT" ]; then
          echo "Found latest ZFS snapshot: $LATEST_SNAPSHOT"
          echo "Attempting to roll back..."
          if zfs rollback -r "$LATEST_SNAPSHOT"; then
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

        # Step 3: Attempt Restic restore (slower, from remote)
        echo "Attempting Restic restore from repository '${resticRepoUrl}'..."

        RESTIC_ARGS=(
          -r "${resticRepoUrl}"
          --password-file "${resticPasswordFile}"
          ${lib.optionalString (resticEnvironmentFile != null) "--env-file ${resticEnvironmentFile}"}
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
          echo "Restic restore failed."
        fi

        # Step 4: All restore methods failed
        ${notify "preseed-failure" "All restore attempts for ${serviceName} failed. Service will start with an empty data directory."}
        echo "Allowing ${serviceName} to start with an empty data directory."
        exit 0 # Exit successfully to not block service start
      '';
    };
  };
}
