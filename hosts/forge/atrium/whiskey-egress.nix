{ ... }:
{
  # Hostname-only active configuration and subscription inventory, 2026-09-18.
  services.atriumForge.whiskeyEgress = {
    dnsAddresses = [ "10.20.0.15" ];
    dynamicHosts = {
      calendar = [ "calendars.partiful.com" ];
      media = [ "whiskeywhiskeywhiskey.org" ];
      webpush = [ "web.push.apple.com" ];
    };
  };
}
