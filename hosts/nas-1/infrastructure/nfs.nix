# hosts/nas-1/infrastructure/nfs.nix
#
# NFS server configuration for nas-1
#
# Exports:
# - /mnt/backup/forge/restic      - Restic backup repository (non-database data)
# - /mnt/backup/forge/postgresql  - pgBackRest backups (PostgreSQL only)
# - /mnt/backup/forge/docs        - Documentation backups

{ ... }:

{
  # =============================================================================
  # NFS Server
  # =============================================================================

  services.nfs.server = {
    enable = true;

    exports = ''
      # Restic backup storage (non-database data from forge)
      # no_root_squash allows forge's restic-backup user to write with preserved ownership
      /mnt/backup/forge/restic forge.holthome.net(rw,sync,no_subtree_check,no_root_squash)

      # PostgreSQL backups via pgBackRest (dedicated mount for isolation)
      /mnt/backup/forge/postgresql forge.holthome.net(rw,sync,no_subtree_check,no_root_squash)

      # Documentation backups (disaster recovery docs, runbooks)
      /mnt/backup/forge/docs forge.holthome.net(rw,sync,no_subtree_check,no_root_squash)
    '';
  };

  # Use NFSv4 with proper ID mapping (new format - replaces deprecated extraNfsdConfig)
  services.nfs.settings = {
    nfsd = {
      vers4 = true;
      "vers4.0" = true;
      "vers4.1" = true;
      "vers4.2" = true;
    };
  };

  # =============================================================================
  # NFS Dependencies
  # =============================================================================

  # Ensure NFS starts after ZFS pools are imported
  systemd.services.nfs-server = {
    after = [ "zfs-import.target" ];
    wants = [ "zfs-import.target" ];
  };

  # RPC bind for NFSv3 compatibility (some older clients may need it)
  services.rpcbind.enable = true;

  # =============================================================================
  # ID Mapping (for NFSv4)
  # =============================================================================

  # Configure ID mapping domain
  services.nfs.idmapd.settings = {
    General = {
      Domain = "holthome.net";
    };
  };
}
