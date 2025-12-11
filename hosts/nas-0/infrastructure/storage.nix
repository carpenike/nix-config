# hosts/nas-0/infrastructure/storage.nix
#
# ZFS storage configuration for nas-0
#
# nas-0 has two ZFS pools:
# - rpool: Boot SSD (managed by disko)
# - tank: 117TB across 14 mirror vdevs (imported via boot.zfs.extraPools)
#
# The tank pool contains the primary data:
# - tank/share: Media files (86.6TB) - exported via NFS to forge
# - tank/home: User home directories (1.99TB)
# - tank/minio: Object storage (556GB)
# - tank/.system: TrueNAS system data (will be cleaned up post-migration)
#
# Replication Strategy:
# nas-0 replicates critical datasets to nas-1 for redundancy:
# - tank/share → backup/nas-0/share (on nas-1)
# - tank/home → backup/nas-0/home (on nas-1)

{ config, lib, ... }:

{
  # =============================================================================
  # Sanoid Configuration (Snapshot Management)
  # =============================================================================

  # Static sanoid user (don't use DynamicUser for ZFS permission stability)
  users.users.sanoid = {
    isSystemUser = true;
    group = "sanoid";
    description = "Sanoid ZFS snapshot management user";
  };

  users.groups.sanoid = { };

  # Override sanoid service to use static user
  systemd.services.sanoid.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "sanoid";
    Group = "sanoid";
  };

  services.sanoid = {
    enable = true;

    templates = {
      # Template for production data - frequent snapshots
      production = {
        hourly = 24;
        daily = 30;
        weekly = 8;
        monthly = 12;
        yearly = 1;
        autosnap = true;
        autoprune = true;
      };

      # Template for bulk media - less frequent (large dataset)
      media = {
        hourly = 0; # No hourly for huge media dataset
        daily = 7;
        weekly = 4;
        monthly = 3;
        yearly = 0;
        autosnap = true;
        autoprune = true;
      };

      # Template for local rpool - CREATE snapshots for local replication
      local = {
        hourly = 24;
        daily = 7;
        weekly = 4;
        monthly = 3;
        yearly = 0;
        autosnap = true;
        autoprune = true;
      };
    };

    datasets = {
      # =========================================================================
      # LOCAL rpool datasets (boot SSD)
      # =========================================================================
      "rpool/safe/persist" = {
        useTemplate = [ "local" ];
        recursive = false;
      };

      "rpool/safe/home" = {
        useTemplate = [ "local" ];
        recursive = false;
      };

      # =========================================================================
      # Tank pool datasets (primary storage)
      # =========================================================================
      "tank/share" = {
        useTemplate = [ "media" ];
        recursive = false; # Don't snapshot subdatasets separately
      };

      "tank/home" = {
        useTemplate = [ "production" ];
        recursive = false;
      };

      "tank/minio" = {
        useTemplate = [ "production" ];
        recursive = false;
      };
    };
  };

  # =============================================================================
  # Syncoid Configuration (Replication to nas-1)
  # =============================================================================

  # Replicate critical datasets to nas-1 for redundancy
  # Note: tank/share is huge (86TB), so we may want to be selective

  services.syncoid = {
    enable = true;
    interval = "daily"; # Daily replication for large datasets

    # SSH key for connecting to nas-1
    sshKey = "/var/lib/zfs-replication/.ssh/id_ed25519";

    commands = {
      # Replicate home dataset to nas-1
      # Uses zfs-recv container dataset to separate from potential NFS exports
      "tank/home" = {
        target = "zfs-replication@nas-1.holthome.net:backup/nas-0/zfs-recv/home";
        recursive = false;
        sendOptions = "w"; # Raw send (preserves encryption if any)
      };

      # Optional: Replicate share dataset (86TB - consider carefully!)
      # Uncomment if you want offsite backup of media
      # "tank/share" = {
      #   target = "zfs-replication@nas-1.holthome.net:backup/nas-0/zfs-recv/share";
      #   recursive = false;
      #   sendOptions = "w";
      # };
    };
  };

  # =============================================================================
  # ZFS Permission Delegation
  # =============================================================================

  systemd.services.zfs-delegate-permissions = {
    description = "Delegate ZFS permissions for Sanoid and Syncoid";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs-import.target" ];
    before = [ "sanoid.service" "syncoid.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Grant permissions for sanoid on rpool
      ${config.boot.zfs.package}/bin/zfs allow sanoid \
        destroy,hold,send,snapshot \
        rpool/safe || true

      # Grant permissions for sanoid on tank
      ${config.boot.zfs.package}/bin/zfs allow sanoid \
        destroy,hold,send,snapshot \
        tank || true

      # Grant permissions for syncoid/zfs-replication to send
      ${config.boot.zfs.package}/bin/zfs allow zfs-replication \
        bookmark,hold,send,snapshot \
        tank || true

      echo "ZFS permissions applied successfully"
    '';
  };

  # =============================================================================
  # ZFS Event Daemon (zed) for alerts
  # =============================================================================

  services.zfs.zed = {
    enableMail = false; # TODO: Configure notifications
    settings = {
      ZED_DEBUG_LOG = "/var/log/zed.debug.log";

      # Notify on pool errors
      ZED_NOTIFY_INTERVAL_SECS = 3600;
      ZED_NOTIFY_VERBOSE = true;
    };
  };
}
