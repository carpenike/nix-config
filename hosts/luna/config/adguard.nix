{
  config,
  lib,
  ...
}:
{
  schema_version = 24;
  # bind_host and bind_port now managed by the AdGuardHome module
  theme = "auto";
  users = [{
    name = "ryan";
    password = "ADGUARDPASS";
  }];
  dns = {
    bind_hosts = ["0.0.0.0"];  # Listen on all interfaces
    port = 53;
    bootstrap_dns = [
      # quad9
      "9.9.9.10"
      "149.112.112.10"
      "2620:fe::10"
      "2620:fe::fe:10"

      # cloudflare
      "1.1.1.1"
      "2606:4700:4700::1111"
    ];
    # Local domain routing (replacing dnsdist functionality)
    upstream_dns = [
      # Local domains to BIND
      "[/holthome.net/]127.0.0.1:5391"
      "[/unifi/]127.0.0.1:5391"
      "[/in-addr.arpa/]127.0.0.1:5391"  # Reverse DNS for hostname logging
      "[/ip6.arpa/]127.0.0.1:5391"     # IPv6 reverse DNS
      # RV domain routing (was in dnsdist)
      "[/holtel.io/]192.168.88.1:53"
      # Global upstreams
      "https://1.1.1.1/dns-query"
      "https://1.0.0.1/dns-query"
    ];
    upstream_mode = "load_balance";
    fallback_dns = [];  # Not needed with two load-balanced DoH upstreams
    local_ptr_upstreams = [ "127.0.0.1:5391" ];  # For local hostname resolution
    use_private_ptr_resolvers = true;

    # security
    enable_dnsseec = true;

    # local cache settings
    cache_size = 100000000;
    cache_ttl_min = 60;
    cache_optimistic = true;
  };
  filters =
    let
    urls = [
      # --- Core Blocklist ---
      # Comprehensive, balanced list with low false-positive rate. Excellent for family networks.
      { name = "OISD Big"; url = "https://big.oisd.nl/"; }

      # --- High-Value Security Additions ---
      # Focused on malware and phishing with minimal overlap on general ad/tracker blocking.
      { name = "Phishing Army"; url = "https://phishing.army/download/phishing_army_blocklist_extended.txt"; }
      { name = "URLHaus Malware"; url = "https://urlhaus.abuse.ch/downloads/hostfile/"; }
    ];
    buildList = id: url: {
      enabled = true;
      inherit id;
      inherit (url) name;
      inherit (url) url;
    };
    in
    lib.imap1 buildList urls;

  filtering = {
    parental_block_host =  "family-block.dns.adguard.com";
    safebrowsing_block_host = "standard-block.dns.adguard.com";
  };

  clients = {
    runtime_sources = {
      whois = true;
      arp = true;
      rdns = true;
      dhcp = true;
      hosts = true;
    };
    persistent = [
      {
        name = "Unfiltered VLANs";
        ids = [
          "10.35.0.0/16"  # Guest VLAN
          "10.8.0.0/24"   # Wireguard
          "10.9.18.0/24"  # Management
          "10.20.0.0/16"  # Servers VLAN
          "10.40.0.0/16"  # IoT VLAN
        ];
        use_global_settings = false;
        filtering_enabled = false;
        safebrowsing_enabled = false;
        parental_enabled = false;
        safesearch = {
          enabled = false;
        };
        use_global_blocked_services = false;
        # Use global upstreams (includes local domain routing)
      }
      {
        name = "Video VLAN";
        ids = [
          "10.50.0.0/16"  # Video VLAN - bypass local domains entirely
        ];
        use_global_settings = false;
        filtering_enabled = false;
        safebrowsing_enabled = false;
        parental_enabled = false;
        safesearch = {
          enabled = false;
        };
        use_global_blocked_services = false;
        upstreams = [
          "https://1.1.1.1/dns-query"
          "https://1.0.0.1/dns-query"
        ];
      }
    ];
  };
}
