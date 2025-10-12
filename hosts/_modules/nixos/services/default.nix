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
    ./cfdyndns
    ./chrony
    ./cloudflared
    ./coachiq
    ./dispatcharr
    ./dnsdist
    ./glances
    ./haproxy
    ./nginx
    ./node-exporter
    ./onepassword-connect
    ./openssh
    ./omada
    ./podman
    ./postgresql          # Options only
    ./postgresql/implementation.nix  # Config generation (separate to avoid circular deps)
    ./sonarr
    ./unifi
  ];
}
