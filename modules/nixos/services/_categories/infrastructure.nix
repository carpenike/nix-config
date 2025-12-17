# Core infrastructure services (networking, databases, reverse proxy)
# Import this category for most hosts - foundational services
{ ... }:
{
  imports = [
    ../bind # DNS server
    ../blocky # DNS proxy/blocker
    ../caddy # Reverse proxy (primary)
    ../chrony # NTP time sync
    ../cloudflared # Cloudflare tunnel
    ../dnsdist # DNS load balancer
    ../haproxy # TCP/HTTP load balancer
    ../nginx # Web server (alternative to Caddy)
    ../openssh # SSH server
    ../podman # Container runtime
    ../postgresql # PostgreSQL database
    ../postgresql/databases.nix # Database provisioning
    ../postgresql/storage-integration.nix # ZFS dataset creation
  ];
}
