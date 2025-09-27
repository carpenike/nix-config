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
    upstream_dns = [
      "[/holthome.net/]127.0.0.1:5391"
      "[/ryho.lt/]127.0.0.1:5391"
      "[/in-addr.arpa/]127.0.0.1:5391"
      "[/ip6.arpa/]127.0.0.1:5391"
      "https://1.1.1.1/dns-query"
    ];
    upstream_mode = "load_balance";
    fallback_dns = [
      "https://dns.cloudflare.com/dns-query"
    ];
    local_ptr_upstreams = [ "127.0.0.1:5391" ];
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
      { name = "AdGuard DNS filter"; url = "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"; }
      { name = "AdAway Default Blocklist"; url = "https://adaway.org/hosts.txt"; }
      { name = "Big OSID"; url = "https://big.oisd.nl"; }
      { name = "1Hosts Lite"; url = "https://o0.pages.dev/Lite/adblock.txt"; }
      { name = "hagezi multi pro"; url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt"; }
      { name = "osint"; url = "https://osint.digitalside.it/Threat-Intel/lists/latestdomains.txt"; }
      { name = "phishing army"; url = "https://phishing.army/download/phishing_army_blocklist_extended.txt"; }
      { name = "notrack malware"; url = "https://gitlab.com/quidsup/notrack-blocklists/raw/master/notrack-malware.txt"; }
      { name = "EasyPrivacy"; url = "https://v.firebog.net/hosts/Easyprivacy.txt"; }
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
