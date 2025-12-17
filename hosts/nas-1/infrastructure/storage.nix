# hosts/nas-1/infrastructure/storage.nix
#
# ZFS storage configuration for nas-1
#
# nas-1 has two ZFS pools:
# - rpool: Boot SSD (managed by disko)
# - backup: 4x14TB RAIDZ1 (imported via boot.zfs.extraPools)
#
# The backup pool contains:
# - backup/forge/*: Replication targets from forge
# - backup/nas-1/*: LOCAL replication from rpool (self-sufficient disaster recovery)
# - backup/home: Replicated from nas-0 (TrueNAS)
# - backup/share: Replicated from nas-0 (TrueNAS)
# - Legacy datasets (minio, vm, etc.) - to be cleaned up
#
# Local Replication Strategy:
# nas-1 replicates its own rpool to the backup pool for self-sufficient disaster
# recovery. This allows quickstart recovery without external dependencies (since
# nas-0 is on the same site, offsite backup has limited value).
#
# Flow: rpool/safe/persist → backup/nas-1/rpool/persist
#       rpool/safe/home    → backup/nas-1/rpool/home

{ config, lib, ... }:

{
  # =============================================================================
  # Sanoid Configuration (Snapshot Pruning)
  # =============================================================================

  # Sanoid on nas-1 is used to PRUNE replicated snapshots, not create new ones.
  # Snapshots are created on the source hosts (forge, nas-0) and replicated here.

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
      # Template for replicated datasets - prune only, no new snapshots
      replicated = {
        hourly = 24;
        daily = 7;
        weekly = 4;
        monthly = 3;
        yearly = 0;
        autosnap = false; # DON'T create new snapshots
        autoprune = true; # DO prune old snapshots
      };

      # Template for local rpool datasets - CREATE snapshots for local replication
      local = {
        hourly = 24;
        daily = 7;
        weekly = 4;
        monthly = 3;
        yearly = 0;
        autosnap = true; # Create snapshots for local replication
        autoprune = true;
      };
    };

    datasets = {
      # =========================================================================
      # LOCAL rpool datasets (source for local replication)
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
      # LOCAL replication targets (backup pool - prune only)
      # =========================================================================
      "backup/nas-1/rpool/persist" = {
        useTemplate = [ "replicated" ];
        recursive = false;
      };

      "backup/nas-1/rpool/home" = {
        useTemplate = [ "replicated" ];
        recursive = false;
      };

      # =========================================================================
      # Forge replicated datasets (prune only)
      # =========================================================================
      # NOTE: Using recursive=true on the parent dataset to automatically
      # prune all child datasets (50+ services) without listing each one.
      # This keeps the config maintainable as forge adds new services.
      "backup/forge/zfs-recv" = {
        useTemplate = [ "replicated" ];
        recursive = true; # Prune all child datasets automatically
      };

      # Individual datasets that need special handling can override:
      # "backup/forge/zfs-recv/plex" = {
      #   useTemplate = [ "replicated" ];
      #   recursive = false;
      #   hourly = 48;  # Keep more hourly snapshots for large dataset
      # };
    };
  };

  # =============================================================================
  # Syncoid Configuration (Local Replication)
  # =============================================================================

  # Local replication from rpool to backup pool for self-sufficient disaster recovery.
  # This runs entirely on nas-1 (no SSH, no remote host).

  services.syncoid = {
    enable = true;
    interval = "hourly";

    # Local replication doesn't need SSH
    localSourceAllow = [
      "bookmark"
      "hold"
      "send"
      "snapshot"
      "destroy"
    ];

    localTargetAllow = [
      "change-key"
      "compression"
      "create"
      "destroy"
      "hold"
      "mount"
      "mountpoint"
      "receive"
      "rollback"
    ];

    commands = {
      # Replicate persist dataset locally
      "rpool/safe/persist" = {
        target = "backup/nas-1/rpool/persist";
        recursive = false;
        # No sshKey needed - local replication
      };

      # Replicate home dataset locally
      "rpool/safe/home" = {
        target = "backup/nas-1/rpool/home";
        recursive = false;
      };
    };
  };

  # =============================================================================
  # ZFS Permission Delegation
  # =============================================================================

  # Grant ZFS permissions to sanoid for pruning
  systemd.services.zfs-delegate-permissions-sanoid = {
    description = "Delegate ZFS permissions for Sanoid pruning";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs-import.target" ];
    before = [ "sanoid.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Grant permissions for managing replicated snapshots (from forge)
      ${config.boot.zfs.package}/bin/zfs allow sanoid \
        destroy,hold,send,snapshot \
        backup/forge/zfs-recv || true

      # Grant permissions for local rpool snapshots
      ${config.boot.zfs.package}/bin/zfs allow sanoid \
        destroy,hold,send,snapshot \
        rpool/safe || true

      # Grant permissions for local replication targets
      ${config.boot.zfs.package}/bin/zfs allow sanoid \
        destroy,hold,send,snapshot \
        backup/nas-1 || true

      echo "Sanoid ZFS permissions applied successfully"
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
