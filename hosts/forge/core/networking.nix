{ hostname, ... }:

{
  # Increase multicast group membership limit for mDNS discovery.
  # ESPHome (and other mDNS services) join multicast groups per device.
  # Default limit (20) is easily exceeded with many IoT devices.
  boot.kernel.sysctl."net.ipv4.igmp_max_memberships" = 1024;

  networking = {
    hostName = hostname;
    hostId = "1b3031e7"; # Preserved from nixos-bootstrap
    useDHCP = true;
    domain = "holthome.net";

    # Firewall enabled - services opt-in via openFirewall options
    firewall = {
      enable = true;
      # Allow ICMP ping for network diagnostics
      allowPing = true;
      # Log denied packets for debugging (can be disabled once stable)
      logRefusedConnections = true;
    };

    # VLAN 30: Wireless network for Home Assistant mDNS device discovery
    # Allows HA to directly communicate with devices on the wireless VLAN
    # Uses static IP to prevent Mikrotik from registering dynamic DNS for this interface
    vlans.wireless = {
      id = 30;
      interface = "enp8s0";
    };

    interfaces.wireless = {
      useDHCP = false;
      ipv4.addresses = [{
        address = "10.30.0.30";
        prefixLength = 24;
      }];
    };

    # REMOVED 2025-11-01: These /etc/hosts entries are no longer needed.
    # The TLS certificate exporter was rewritten to read cert files directly from disk
    # instead of making network connections via openssl s_client. All intra-host
    # monitoring connections properly use 127.0.0.1 or localhost directly in their
    # scrape configs. Keeping these entries created confusing split-horizon DNS behavior.
    #
    # Commented out for observation period - will be fully removed if no issues arise.
    #
    # extraHosts = ''
    #   127.0.0.1 am.holthome.net
    #   127.0.0.1 prom.holthome.net
    #   127.0.0.1 loki.holthome.net
    #   127.0.0.1 grafana.holthome.net
    #   127.0.0.1 iptv.holthome.net
    #   127.0.0.1 plex.holthome.net
    # '';
  };
}
