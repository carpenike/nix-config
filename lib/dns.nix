# DNS utility functions
# Shared functions for DNS record management across the fleet
{ lib }:
{
  # Extracts subdomain from FQDN by removing the base domain
  # Example: "omada.holthome.net" with domain "holthome.net" -> "omada"
  #
  # Args:
  #   fqdn: Fully qualified domain name (e.g., "omada.holthome.net")
  #   domain: Base domain to remove (e.g., "holthome.net")
  # Returns:
  #   Subdomain string if FQDN matches domain, otherwise returns FQDN unchanged
  extractSubdomain = fqdn: domain:
    let
      domainSuffix = ".${domain}";
      fqdnLength = lib.stringLength fqdn;
      suffixLength = lib.stringLength domainSuffix;
    in
    if lib.hasSuffix domainSuffix fqdn
    then lib.substring 0 (fqdnLength - suffixLength) fqdn
    else fqdn; # Return as-is if doesn't match domain
}
