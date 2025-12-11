# hosts/nas-0/infrastructure/nfs.nix
#
# NFS Server configuration for nas-0
#
# nas-0 is the primary file server for the homelab, providing NFS exports to:
# - forge: Media files for Plex, Sonarr, Radarr, etc.
# - Other hosts: User home directories, shared storage
#
# DNS: nas-0.holthome.net, nas.holthome.net (alias used by forge)
#
# Current exports (migrated from TrueNAS):
# - /mnt/tank/share: Main media storage (mapall=ryan:wheel)
# - /mnt/tank/home: User home directories
# - /mnt/tank/share/pictures: Photo storage (subset of share)
#
# Client configuration (forge):
#   device = "nas.holthome.net:/mnt/tank/share"
#   options = [ "nfsvers=4.2" "noatime" "x-systemd.automount" ]

{ ... }:

{
  # =============================================================================
  # NFS Server Configuration
  # =============================================================================

  services.nfs.server = {
    enable = true;

    # Number of NFS threads (adjust based on load)
    nproc = 8;

    # Enable NFSv4 with proper ID mapping
    # Note: statdPort, lockdPort, mountdPort are set below for firewall
    statdPort = 4000;
    lockdPort = 4001;
    mountdPort = 4002;

    exports = ''
      # Main media share - all media for Plex and download services
      # Access: 10.20.0.0/16 (homelab network)
      # Options:
      #   rw: Read-write access
      #   sync: Synchronous writes (data safety)
      #   no_subtree_check: Better performance, safe for non-exported parent
      #   no_root_squash: Allow root access (needed for some services)
      #   all_squash: Squash all users to anonuid/anongid
      #   anonuid/anongid: Map to ryan (1000) for consistent permissions
      /mnt/tank/share 10.20.0.0/16(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=100)

      # User home directories
      # More restrictive - only specific hosts
      /mnt/tank/home 10.20.0.0/16(rw,sync,no_subtree_check,root_squash)

      # Pictures share (subset of share, separate export for specific clients)
      # Used by photo management services
      /mnt/tank/share/pictures 10.20.0.0/16(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=100)
    '';
  };

  # =============================================================================
  # NFSv4 ID Mapping
  # =============================================================================

  # Enable NFSv4 ID mapping for proper username resolution
  services.nfs.idmapd.settings = {
    General = {
      Domain = "holthome.net";
    };
    Mapping = {
      Nobody-User = "nobody";
      Nobody-Group = "nogroup";
    };
  };

  # =============================================================================
  # Firewall Configuration
  # =============================================================================

  # Note: Main NFS ports are opened in core/networking.nix
  # This section documents the complete NFS port requirements:
  #
  # TCP/UDP 2049: NFS
  # TCP/UDP 111: RPC portmapper
  # TCP/UDP 4000: statd
  # TCP/UDP 4001: lockd
  # TCP/UDP 4002: mountd

  networking.firewall = {
    # Open the auxiliary NFS ports
    allowedTCPPorts = [ 4000 4001 4002 ];
    allowedUDPPorts = [ 4000 4001 4002 ];
  };

  # =============================================================================
  # Performance Tuning
  # =============================================================================

  # Increase NFS read/write sizes for better performance over 10GbE
  boot.kernel.sysctl = {
    # Increase socket buffer sizes for NFS
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_rmem" = "4096 87380 16777216";
    "net.ipv4.tcp_wmem" = "4096 87380 16777216";
  };
}
