# hosts/nas-0/infrastructure/smb.nix
#
# Samba (SMB) Server configuration for nas-0
#
# Provides Windows/macOS file sharing for desktop clients.
# SMB shares mirror the NFS exports for client compatibility.
#
# Shares:
# - share: Main media storage (same as /mnt/tank/share)
# - home: User home directories
# - pictures: Photo storage
#
# Access: Username/password authentication via smbpasswd
# Protocol: SMB2 minimum (no SMBv1 for security)

{ pkgs, ... }:

{
  # =============================================================================
  # Samba Server Configuration
  # =============================================================================

  services.samba = {
    enable = true;
    package = pkgs.samba;

    # Global settings
    settings = {
      global = {
        # Server identification
        workgroup = "HOLTHOME";
        "server string" = "nas-0";
        "netbios name" = "nas-0";

        # Security settings
        security = "user";
        "server min protocol" = "SMB2_02"; # No SMBv1
        "server max protocol" = "SMB3";
        "client min protocol" = "SMB2_02";
        "client max protocol" = "SMB3";

        # Disable guest access
        "map to guest" = "never";
        "guest ok" = "no";

        # macOS compatibility
        "fruit:metadata" = "stream";
        "fruit:model" = "MacSamba";
        "fruit:posix_rename" = "yes";
        "fruit:veto_appledouble" = "no";
        "fruit:nfs_aces" = "no";
        "fruit:wipe_intentionally_left_blank_rfork" = "yes";
        "fruit:delete_empty_adfiles" = "yes";

        # VFS modules for macOS
        "vfs objects" = "fruit streams_xattr";

        # Logging
        logging = "systemd";
        "log level" = "1";

        # Performance
        "socket options" = "TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072";
        "use sendfile" = "yes";
        "aio read size" = "16384";
        "aio write size" = "16384";

        # Disable printing
        "load printers" = "no";
        printing = "bsd";
        "printcap name" = "/dev/null";
        "disable spoolss" = "yes";

        # Enable WINS for local name resolution
        "wins support" = "yes";
      };

      # =========================================================================
      # Share Definitions
      # =========================================================================

      # Main media share
      share = {
        path = "/mnt/tank/share";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "valid users" = "ryan";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = "ryan";
        "force group" = "users";
        comment = "Media and shared files";
      };

      # User home directories
      home = {
        path = "/mnt/tank/home";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "valid users" = "ryan";
        "create mask" = "0640";
        "directory mask" = "0750";
        comment = "User home directories";
      };

      # Pictures share
      pictures = {
        path = "/mnt/tank/share/pictures";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "valid users" = "ryan";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = "ryan";
        "force group" = "users";
        comment = "Photo storage";
      };
    };
  };

  # =============================================================================
  # Samba Discovery (mDNS/Avahi)
  # =============================================================================

  # Announce SMB shares via Avahi for easy discovery on macOS/iOS
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      domain = true;
      workstation = true;
    };
    extraServiceFiles = {
      smb = ''
        <?xml version="1.0" standalone='no'?>
        <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
        <service-group>
          <name replace-wildcards="yes">%h</name>
          <service>
            <type>_smb._tcp</type>
            <port>445</port>
          </service>
        </service-group>
      '';
    };
  };

  # =============================================================================
  # Firewall Configuration
  # =============================================================================

  # Note: Main SMB ports (139, 445) are opened in core/networking.nix
  # wsdd port for Windows discovery
  networking.firewall = {
    allowedTCPPorts = [ 5357 ]; # Web Services for Devices (Windows discovery)
    allowedUDPPorts = [ 3702 ]; # WS-Discovery
  };
}
