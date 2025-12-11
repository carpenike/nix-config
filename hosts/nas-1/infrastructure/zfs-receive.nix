# hosts/nas-1/infrastructure/zfs-receive.nix
#
# ZFS replication receiver configuration for nas-1
#
# nas-1 receives ZFS snapshots from:
# - forge: via syncoid (using zfs-replication user)
# - nas-0: via TrueNAS replication tasks (uses its own credentials)
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
    after = [ "zfs-import.target" ];
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

      ${config.boot.zfs.package}/bin/zfs allow zfs-replication \
        bookmark,compression,create,destroy,hold,mount,mountpoint,receive,recordsize,rollback,send,snapdir \
        backup/forge/zfs-recv || true

      ${config.boot.zfs.package}/bin/zfs allow zfs-replication \
        bookmark,compression,create,destroy,hold,mount,mountpoint,receive,recordsize,rollback,send,snapdir \
        backup/forge/services || true

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
        $ZFS set canmount=off backup/forge/zfs-recv
        echo "Created backup/forge/zfs-recv dataset"
      fi

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

      echo "ZFS receive datasets initialized"
    '';
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
