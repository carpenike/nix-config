# Service categories index
#
# All categories are imported unconditionally by design: every service module
# is gated behind its own `modules.services.<name>.enable` option, so importing
# a module a host never enables costs nothing at runtime. The category files
# exist purely to keep this list organized/readable — there is no selective
# category loading mechanism.
#
# Categories:
#   ./media.nix           - *arr stack, Plex, media management
#   ./media-automation.nix - Profilarr, Recyclarr, Dispatcharr
#   ./downloads.nix       - qBittorrent, SABnzbd, download clients
#   ./home-automation.nix - Home Assistant, ESPHome, IoT
#   ./infrastructure.nix  - Caddy, PostgreSQL, core services
#   ./observability.nix   - Grafana, Loki, monitoring
#   ./auth.nix            - PocketID, 1Password Connect
#   ./productivity.nix    - Paperless, Mealie, self-hosted apps
#   ./ai.nix              - LiteLLM, Open WebUI
#   ./development.nix     - GitHub Runner, Attic, dev tools
#   ./backup.nix          - Backup management, Resilio
#   ./network.nix         - UniFi, Omada, network controllers
#   ./automotive.nix      - TeslaMate, vehicle telemetry
{ ... }:
{
  imports = [
    ./ai.nix
    ./auth.nix
    ./automotive.nix
    ./backup.nix
    ./development.nix
    ./downloads.nix
    ./home-automation.nix
    ./infrastructure.nix
    ./media.nix
    ./media-automation.nix
    ./network.nix
    ./observability.nix
    ./productivity.nix
  ];
}
