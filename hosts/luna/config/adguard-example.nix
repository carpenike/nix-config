# Example of using AdGuard Home with minimal baseline configuration
# This shows how to enable AdGuard with only infrastructure-critical settings
# Everything else should be configured via the web UI

{
  modules.services.adguardhome = {
    enable = true;
    shared = {
      enable = true;

      # Only override if you need different ports
      # webPort = 3000;  # default
      # dnsPort = 5390;  # default to avoid conflicts with BIND on 5391

      # Admin user for web UI
      adminUser = "ryan";

      # Local DNS forwarding for internal domains
      # This is critical for infrastructure - ensures internal domains work
      localDnsServer = "127.0.0.1:5391";  # BIND on this host
      localDomains = [
        "holthome.net"
        "ryho.lt"
        "in-addr.arpa"
        "ip6.arpa"
      ];

      # That's it! Everything else via web UI:
      # - Filters and blocklists
      # - Client configurations
      # - Parental controls
      # - Additional DNS upstreams
      # - Safe search settings
      # - Query logging settings
      # - DHCP settings
      # etc.
    };
  };
}
