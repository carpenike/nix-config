{
  ...
}:
{
  imports = [
    ./adguardhome
    ./attic.nix
    ./attic-admin.nix
    ./bind
    ./blocky
    ./caddy
    ./reverse-proxy/registry.nix  # Shared reverse proxy registration interface
    ./cfdyndns
    ./chrony
    ./cloudflared
    ./coachiq
    ./dispatcharr
    ./dnsdist
    ./glances
    ./grafana                                 # Grafana monitoring dashboard
    ./haproxy
    ./loki                                    # Loki log aggregation server
    ./nginx
    ./node-exporter
    ./observability                           # Unified observability stack (Loki + Promtail)
    ./onepassword-connect
    ./openssh
    ./omada
    ./podman
    ./postgresql                              # PostgreSQL module (simplified single-instance)
    ./postgresql/databases.nix                # Database provisioning (systemd units)
    ./postgresql/storage-integration.nix      # ZFS dataset creation (one-way integration)
    # ./postgresql/backup-integration.nix     # REMOVED: PostgreSQL backups now handled by pgBackRest
    ./promtail                                # Promtail log shipping agent
    ./sonarr
    ./unifi
    # ./ups                                   # REMOVED: Use services.nut directly in host configs
  ];
}
