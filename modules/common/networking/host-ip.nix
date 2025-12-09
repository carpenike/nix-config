# Declares the primary IP address for this host
# Used for DNS record generation across the fleet
{ lib, ... }:
{
  options.my.hostIp = lib.mkOption {
    type = lib.types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}";
    description = "Primary IPv4 address for this host (used for DNS A records)";
    example = "10.20.0.15";
  };
}
