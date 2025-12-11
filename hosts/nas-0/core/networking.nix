# hosts/nas-0/core/networking.nix
#
# Network configuration for nas-0
#
# Primary interface: ix0 (Intel 10GbE)
# Static IP: 10.20.0.10/16
# DNS alias: nas.holthome.net

{ ... }:

{
  # =============================================================================
  # Network Configuration
  # =============================================================================

  networking = {
    # Use systemd-networkd for network configuration
    useNetworkd = true;
    useDHCP = false;

    # Firewall configuration
    firewall = {
      enable = true;

      # NFS + SMB ports
      allowedTCPPorts = [
        111 # rpcbind
        2049 # nfsd
        20048 # mountd
        139 # NetBIOS
        445 # SMB
      ];
      allowedUDPPorts = [
        111 # rpcbind
        2049 # nfsd
        20048 # mountd
      ];

      # Tailscale interface is trusted
      trustedInterfaces = [ "tailscale0" ];
    };

    # Static DNS configuration
    nameservers = [ "10.20.0.15" ];
    search = [ "holthome.net" ];
  };

  # =============================================================================
  # systemd-networkd Configuration
  # =============================================================================

  systemd.network = {
    enable = true;

    # Wait for network to be fully online
    wait-online = {
      anyInterface = true;
      timeout = 30;
    };

    networks = {
      # Primary interface - Intel 10GbE (ix0 in FreeBSD, likely enp* in Linux)
      "10-primary" = {
        matchConfig = {
          # Match by MAC address for stability across driver changes
          # MAC from TrueNAS: ac:1f:6b:1a:8e:40
          MACAddress = "ac:1f:6b:1a:8e:40";
        };
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = false;
        };
        address = [ "10.20.0.10/16" ];
        gateway = [ "10.20.0.1" ];
        dns = [ "10.20.0.15" ];
        domains = [ "holthome.net" ];
      };
    };
  };

  # =============================================================================
  # Additional Network Services
  # =============================================================================

  # Disable resolved, use static DNS
  services.resolved.enable = false;
}
