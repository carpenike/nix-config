# A local recursive resolver for Stalwart. The edge's checks (SPF, DKIM,
# DMARC, reverse DNS, MX) are all DNS, and DNS blocklists such as Spamhaus
# refuse queries that arrive through large shared resolvers, so the edge
# resolves from its own address instead of Vultr's or the tailnet's.
_:
{
  services.unbound = {
    enable = true;
    # Puts 127.0.0.1 and ::1 in /etc/resolv.conf ahead of the DHCP servers. The
    # Stalwart container uses the host network, so it reaches it too.
    resolveLocalQueries = true;
    settings.server = {
      interface = [ "127.0.0.1" "::1" ];
      access-control = [ "127.0.0.0/8 allow" "::1/128 allow" ];
      # Recursive with DNSSEC validation (the module's root trust anchor).
      prefetch = true;
      qname-minimisation = true;
    };
  };
}
