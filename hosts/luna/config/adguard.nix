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
    bind_hosts = ["127.0.0.1"];
    port = 5392;
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
    # Simplified upstream - dnsdist handles ALL routing except reverse DNS
    upstream_dns = [
      "[/in-addr.arpa/]127.0.0.1:5391"  # Only reverse DNS for hostname logging
      "[/ip6.arpa/]127.0.0.1:5391"     # IPv6 reverse DNS
      "https://1.1.1.1/dns-query"
      "https://1.0.0.1/dns-query"  # Added for redundancy
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
  };
}
