# hosts/nas-1/infrastructure/zfs-receive.nix
#
# ZFS replication receiver configuration for nas-1
#
# nas-1 receives ZFS snapshots from:
# - forge: via syncoid (using zfs-replication user)
# - nas-0: via syncoid (using zfs-replication user)
#
# This file configures the permissions and datasets needed to receive replication.

{ config, ... }:

{
  # =============================================================================
  # ZFS Permission Delegation for Replication
  # =============================================================================

  # Grant ZFS permissions to zfs-replication user for receiving snapshots from forge
  systemd.services.zfs-delegate-permissions-receive = {
    description = "Delegate ZFS permissions for receiving ZFS replication";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs-import.target" "zfs-init-receive-datasets.service" ];
    requires = [ "zfs-init-receive-datasets.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for ZFS to be fully ready
      sleep 2

      # Grant receive permissions for forge backups
      # Permissions needed:
      # - receive: Accept incoming snapshots
      # - create: Create new datasets during receive
      # - mount/mountpoint: Handle dataset mounting
      # - compression: Inherit compression settings
      # - destroy: Allow syncoid to clean up old snapshots
      # - rollback: Allow rollback during replication errors
      # - hold: Place holds on snapshots during transfer
      # - bookmark: Manage bookmarks for resumable sends
      # - canmount: Allow post-replication fixup to set canmount=noauto

      ${config.boot.zfs.package}/bin/zfs allow zfs-replication \
        bookmark,canmount,compression,create,destroy,hold,mount,mountpoint,receive,recordsize,rollback,send,snapdir \
        backup/forge/zfs-recv || true

      ${config.boot.zfs.package}/bin/zfs allow zfs-replication \
        bookmark,canmount,compression,create,destroy,hold,mount,mountpoint,receive,recordsize,rollback,send,snapdir \
        backup/forge/services || true

      # Grant receive permissions for nas-0 backups
      ${config.boot.zfs.package}/bin/zfs allow zfs-replication \
        bookmark,canmount,compression,create,destroy,hold,mount,mountpoint,receive,recordsize,rollback,send,snapdir \
        backup/nas-0/zfs-recv || true

      echo "ZFS receive permissions applied for zfs-replication user"
    '';
  };

  # =============================================================================
  # Dataset Initialization
  # =============================================================================

  # Ensure required datasets exist with proper properties
  # These are created once and then receive replicated data
  systemd.services.zfs-init-receive-datasets = {
    description = "Initialize ZFS datasets for receiving replication";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs-import.target" ];
    before = [ "zfs-delegate-permissions-receive.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ZFS="${config.boot.zfs.package}/bin/zfs"

      # Create parent dataset for forge if it doesn't exist
      if ! $ZFS list backup/forge >/dev/null 2>&1; then
        $ZFS create backup/forge
        $ZFS set compression=lz4 backup/forge
        $ZFS set atime=off backup/forge
        echo "Created backup/forge dataset"
      fi

      # Create zfs-recv container dataset (canmount=off - children mount, not this)
      if ! $ZFS list backup/forge/zfs-recv >/dev/null 2>&1; then
        $ZFS create backup/forge/zfs-recv
        echo "Created backup/forge/zfs-recv dataset"
      fi
      # Always ensure canmount=off on the parent (idempotent)
      $ZFS set canmount=off backup/forge/zfs-recv

      # Create services container dataset
      if ! $ZFS list backup/forge/services >/dev/null 2>&1; then
        $ZFS create backup/forge/services
        $ZFS set canmount=off backup/forge/services
        echo "Created backup/forge/services dataset"
      fi

      # Create restic repository dataset (for NFS export)
      if ! $ZFS list backup/forge/restic >/dev/null 2>&1; then
        $ZFS create backup/forge/restic
        $ZFS set recordsize=1M backup/forge/restic
        echo "Created backup/forge/restic dataset"
      fi

      # Create postgresql backup dataset (for NFS export)
      if ! $ZFS list backup/forge/postgresql >/dev/null 2>&1; then
        $ZFS create backup/forge/postgresql
        $ZFS set recordsize=128K backup/forge/postgresql
        echo "Created backup/forge/postgresql dataset"
      fi

      # Create docs backup dataset (for NFS export)
      if ! $ZFS list backup/forge/docs >/dev/null 2>&1; then
        $ZFS create backup/forge/docs
        $ZFS set recordsize=128K backup/forge/docs
        echo "Created backup/forge/docs dataset"
      fi

      # =======================================================================
      # nas-0 backup datasets
      # =======================================================================

      # Create parent dataset for nas-0 if it doesn't exist
      if ! $ZFS list backup/nas-0 >/dev/null 2>&1; then
        $ZFS create backup/nas-0
        $ZFS set compression=lz4 backup/nas-0
        $ZFS set atime=off backup/nas-0
        echo "Created backup/nas-0 dataset"
      fi

      # Create zfs-recv container dataset (canmount=off - children mount, not this)
      # Mirrors forge's pattern: separates replicated data from potential NFS exports
      if ! $ZFS list backup/nas-0/zfs-recv >/dev/null 2>&1; then
        $ZFS create backup/nas-0/zfs-recv
        echo "Created backup/nas-0/zfs-recv dataset"
      fi
      # Always ensure canmount=off on the parent (idempotent)
      $ZFS set canmount=off backup/nas-0/zfs-recv

      # Child datasets are created automatically by syncoid on first receive

      echo "ZFS receive datasets initialized"
    '';
  };

  # =============================================================================
  # Prevent Replicated Datasets from Auto-Mounting to Conflicting Paths
  # =============================================================================

  # Child datasets under zfs-recv inherit their mountpoint from the source (forge).
  # For example, backup/forge/zfs-recv/grafana has mountpoint=/var/lib/grafana.
  # By default canmount=on, which causes ZFS to try mounting these read-only
  # datasets at boot, conflicting with local paths on nas-1.
  #
  # PRIMARY DEFENSE: forge runs syncoid-post-fixup-nas1 immediately after
  # replication completes, setting canmount=noauto on new datasets.
  #
  # SECONDARY DEFENSE (this service): Boot-time and hourly fixup catches any
  # datasets that were missed (e.g., if forge's post-hook failed) and also
  # sets org.openzfs.systemd:ignore to tell systemd mount-generator to skip them.
  systemd.services.zfs-disable-recv-automount = {
    description = "Prevent replicated ZFS datasets from auto-mounting";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs-import.target" "zfs-init-receive-datasets.service" ];
    requires = [ "zfs-init-receive-datasets.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ZFS="${config.boot.zfs.package}/bin/zfs"

      # Set canmount=noauto on all child datasets under zfs-recv parents
      # This prevents them from mounting to /var/lib/* or other paths inherited from source
      # Also set org.openzfs.systemd:ignore=on to tell systemd mount-generator to skip them

      for parent in backup/forge/zfs-recv backup/nas-0/zfs-recv backup/forge/services; do
        if $ZFS list "$parent" >/dev/null 2>&1; then
          echo "Processing $parent..."
          for ds in $($ZFS list -H -o name -t filesystem -r "$parent" | tail -n +2); do
            current=$($ZFS get -H -o value canmount "$ds")
            if [ "$current" = "on" ]; then
              echo "Setting canmount=noauto on $ds"
              $ZFS set canmount=noauto "$ds"
            fi
            # Defense-in-depth: tell systemd to ignore these datasets entirely
            ignore=$($ZFS get -H -o value org.openzfs.systemd:ignore "$ds" 2>/dev/null || echo "-")
            if [ "$ignore" != "on" ]; then
              echo "Setting org.openzfs.systemd:ignore=on on $ds"
              $ZFS set org.openzfs.systemd:ignore=on "$ds" 2>/dev/null || true
            fi
          done
        fi
      done

      echo "ZFS receive datasets mount prevention complete"
    '';
  };

  # Run the mount prevention hourly (reduced from daily for faster catch-up)
  # Primary fixup happens via forge's syncoid-post-fixup-nas1 immediately after replication
  systemd.timers.zfs-disable-recv-automount = {
    description = "Hourly check for new replicated datasets needing canmount=noauto";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };

  # =============================================================================
  # SSH Configuration for Replication
  # =============================================================================

  # The zfs-replication user is configured in core/users.nix
  # This just ensures the .ssh directory has correct permissions

  systemd.tmpfiles.rules = [
    "d /var/lib/zfs-replication/.ssh 0700 zfs-replication zfs-replication -"
  ];
}
