{ hostname, ... }:

{
  # Increase multicast group membership limit for mDNS discovery.
  # ESPHome (and other mDNS services) join multicast groups per device.
  # Default limit (20) is easily exceeded with many IoT devices.
  boot.kernel.sysctl."net.ipv4.igmp_max_memberships" = 1024;

  # Enable iproute2 for policy routing table definitions
  networking.iproute2 = {
    enable = true;
    rttablesExtraConfig = ''
      # Table for traffic originating from the main interface
      # Used to prevent asymmetric routing when IoT VLAN clients
      # connect to services on the main IP
      100 main-out
    '';
  };

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

    # VLAN 30: Wireless/IoT network for Home Assistant device discovery
    # Required for receiving UDP broadcasts from devices like WeatherFlow Tempest
    # and Sonos speakers that broadcast on the IoT VLAN (10.30.0.0/16)
    vlans.wireless = {
      id = 30;
      interface = "enp8s0";
    };

    interfaces.wireless = {
      useDHCP = false;
      ipv4.addresses = [{
        address = "10.30.0.30";
        # /16 is required to receive broadcasts from devices across the IoT VLAN
        # (e.g., WeatherFlow at 10.30.100.148 broadcasting to 255.255.255.255)
        prefixLength = 16;
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

  # Policy routing to fix asymmetric routing with IoT VLAN
  #
  # Problem: When a client on 10.30.x.x connects to forge's main IP (10.20.0.30),
  # the reply packets would normally go out the wireless interface (because
  # 10.30.0.0/16 is on-link there) instead of through the default gateway.
  # This causes asymmetric routing which breaks connectivity.
  #
  # Solution: Traffic originating FROM 10.20.0.30 uses a separate routing table
  # that only has the default gateway, ensuring replies go back the same way.
  systemd.services.policy-routing-main = {
    description = "Policy routing for main interface";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ "/run/current-system/sw" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # Use 'replace' for route (idempotent) and delete-before-add for rule
    script = ''
      ip route replace default via 10.20.0.1 dev enp8s0 table main-out
      ip rule del from 10.20.0.30 table main-out priority 100 2>/dev/null || true
      ip rule add from 10.20.0.30 table main-out priority 100
    '';
    preStop = ''
      ip rule del from 10.20.0.30 table main-out priority 100 2>/dev/null || true
      ip route del default via 10.20.0.1 dev enp8s0 table main-out 2>/dev/null || true
    '';
  };
}
