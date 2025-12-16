# Category selector module
# Provides an option for hosts to declare which service categories they need
# When categories are specified, only those categories are imported
# When empty (default), all categories are imported for backward compatibility
{ lib, config, ... }:
let
  cfg = config.modules.services.categories;

  # Map category names to their import paths
  categoryModules = {
    ai = ./ai.nix;
    auth = ./auth.nix;
    automotive = ./automotive.nix;
    backup = ./backup.nix;
    development = ./development.nix;
    downloads = ./downloads.nix;
    home-automation = ./home-automation.nix;
    infrastructure = ./infrastructure.nix;
    media = ./media.nix;
    media-automation = ./media-automation.nix;
    network = ./network.nix;
    observability = ./observability.nix;
    productivity = ./productivity.nix;
  };

  allCategories = builtins.attrNames categoryModules;

  # Determine which categories to load
  # If none specified, load all (backward compatible)
  # If specified, only load those
  selectedCategories =
    if cfg == [ ] then allCategories
    else cfg;

  # Validate that all requested categories exist
  invalidCategories = lib.filter (c: !(builtins.hasAttr c categoryModules)) selectedCategories;

in
{
  options.modules.services.categories = lib.mkOption {
    type = lib.types.listOf (lib.types.enum allCategories);
    default = [ ];
    example = [ "infrastructure" "observability" ];
    description = ''
      List of service categories to import for this host.
      When empty (default), all categories are imported for backward compatibility.

      Available categories:
      - ai: LiteLLM, Open WebUI
      - auth: PocketID, 1Password Connect
      - automotive: TeslaMate
      - backup: Backup management, Resilio Sync
      - development: Attic, GitHub Runner, dev tools
      - downloads: qBittorrent, SABnzbd, Autobrr
      - home-automation: Home Assistant, ESPHome, Frigate
      - infrastructure: Caddy, PostgreSQL, core services
      - media: Plex, *arr stack, Tautulli
      - media-automation: Recyclarr, Profilarr, Dispatcharr
      - network: UniFi, Omada, AdGuard Home
      - observability: Grafana, Loki, Prometheus stack
      - productivity: Paperless, Mealie, self-hosted apps

      Example for a minimal host:
        modules.services.categories = [ "infrastructure" "observability" ];
    '';
  };

  config = {
    assertions = [
      {
        assertion = invalidCategories == [ ];
        message = "Unknown service categories: ${builtins.concatStringsSep ", " invalidCategories}. Valid categories: ${builtins.concatStringsSep ", " allCategories}";
      }
    ];
  };

  # The imports are handled by the parent module based on this option
}
