# Core infrastructure services (networking, databases, reverse proxy)
# Import this category for most hosts - foundational services
{ ... }:
{
  imports = [
    ../apprise # Notification gateway
    ../caddy # Reverse proxy (primary)
    ../chrony # NTP time sync
    ../cloudflared # Cloudflare tunnel
    ../openssh # SSH server
    ../podman # Container runtime
    ../postgresql # PostgreSQL database
    ../postgresql/databases.nix # Database provisioning
    ../postgresql/storage-integration.nix # ZFS dataset creation
  ];
}
