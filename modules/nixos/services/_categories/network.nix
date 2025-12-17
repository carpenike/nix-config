# Network management and controller services
# Import this category for network infrastructure hosts
{ ... }:
{
  imports = [
    ../adguardhome # DNS-level ad blocking
    ../cfdyndns # Cloudflare dynamic DNS
    ../omada # TP-Link Omada controller
    ../unifi # Ubiquiti UniFi controller
  ];
}
