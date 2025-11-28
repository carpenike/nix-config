{ hostname, ... }:

{
  networking = {
    hostName = hostname;
    hostId = "1b3031e7"; # Preserved from nixos-bootstrap
    useDHCP = true;
    # Firewall disabled; per-service modules will declare their own rules
    firewall.enable = false;
    domain = "holthome.net";

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
