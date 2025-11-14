# hosts/forge/services/sonarr.nix
#
# Host-specific configuration for the Sonarr service on 'forge'.
# This module consumes the reusable abstraction defined in:
# hosts/_modules/nixos/services/sonarr/default.nix

{ config, ... }:

{
  config.modules.services.sonarr = {
    enable = true;

    # Pin container image to a specific version with a digest for immutability.
    # Renovate bot can be configured to automate updates.
    image = "ghcr.io/home-operations/sonarr:4.0.15.2940@sha256:ca6c735014bdfb04ce043bf1323a068ab1d1228eea5bab8305ca0722df7baf78";

    # Use shared NFS mount and attach to the media services network.
    nfsMountDependency = "media";
    podmanNetwork = "media-services";
    healthcheck.enable = true;

    # Reverse proxy configuration for external access via Caddy.
    reverseProxy = {
      enable = true;
      hostName = "sonarr.holthome.net";

      # Enable Authelia SSO protection.
      authelia = {
        enable = true;
        instance = "main";
        authDomain = "auth.holthome.net";
        policy = "one_factor";
        allowedGroups = [ "media" ];

        # Bypass authentication for API endpoints, but restrict to internal networks.
        bypassPaths = [ "/api" "/feed" ];
        allowedNetworks = [
          "172.16.0.0/12"  # Docker internal networks
          "192.168.1.0/24" # Local LAN
          "10.0.0.0/8"     # Internal private network range
        ];
      };
    };

    # Enable backups via the custom backup module integration.
    backup = {
      enable = true;
      repository = "nas-primary";
      # NOTE: useSnapshots and zfsDataset are intentionally omitted.
      # The custom Sonarr module at _modules/nixos/services/sonarr/default.nix
      # already defaults these to 'true' and 'tank/services/sonarr' respectively,
      # which is the correct configuration for this host.
    };

    # Enable failure notifications via the custom notifications module.
    notifications.enable = true;

    # Enable self-healing restore from backups before service start.
    preseed = {
      enable = true;
      repositoryUrl = "/mnt/nas-backup";
      passwordFile = config.sops.secrets."restic/password".path;
    };
  };
}
