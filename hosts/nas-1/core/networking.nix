# hosts/nas-1/core/networking.nix
#
# Network configuration for nas-1
# Uses a bridge (br0) for network - bridged from eno1

{ ... }:

{
  # =============================================================================
  # Network Configuration
  # =============================================================================

  networking = {
    # Host identity
    hostName = "nas-1";
    domain = "holthome.net";

    # Use systemd-networkd for declarative networking
    useNetworkd = true;
    useDHCP = false;

    # Bridge configuration
    bridges.br0.interfaces = [ "eno1" ];

    interfaces.br0 = {
      ipv4.addresses = [{
        address = "10.20.0.11";
        prefixLength = 16;
      }];
    };

    defaultGateway = {
      address = "10.20.0.1";
      interface = "br0";
    };

    nameservers = [
      "10.20.0.1" # Local DNS (router/AdGuard)
      "1.1.1.1" # Fallback
    ];

    # Search domain
    search = [ "holthome.net" ];
  };

  # =============================================================================
  # Firewall Configuration
  # =============================================================================

  networking.firewall = {
    enable = true;
    allowPing = true;

    # NFS ports
    allowedTCPPorts = [
      22 # SSH
      111 # rpcbind (NFS)
      2049 # NFS
      # Samba (if needed in future)
      # 139
      # 445
    ];

    allowedUDPPorts = [
      111 # rpcbind (NFS)
      2049 # NFS
    ];

    # Trust Tailscale interface
    trustedInterfaces = [ "tailscale0" ];
  };

  # =============================================================================
  # Time Configuration
  # =============================================================================

  time.timeZone = "America/New_York";
}
