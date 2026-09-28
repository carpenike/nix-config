# hosts/forge/services/github-runner.nix
#
# Host-specific configuration for the GitHub Actions self-hosted runner on 'forge'.
# This enables CI builds to run locally with direct access to Attic cache (when available).
#
# Prerequisites:
# 1. Create a fine-grained PAT at https://github.com/settings/tokens?type=beta
#    - Resource owner: carpenike
#    - Repository access: nix-config (or All repositories)
#    - Permissions: "Self-hosted runners" → Read and write
# 2. Add the token to SOPS secrets:
#    sops secrets/forge.sops.yaml
#    Add: github/runner-token: <your-token>
#
# After deployment, verify at:
#   https://github.com/carpenike/nix-config/settings/actions/runners

{ config, lib, pkgs, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.github-runner.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.github-runner = {
        enable = true;

        # Repository URL - use repo URL for repo-scoped token
        url = "https://github.com/carpenike/nix-config";

        # Token managed via SOPS
        # Note: Using hardcoded path to avoid circular dependency with secrets.nix
        # (secrets.nix checks if this service is enabled, which would evaluate this file)
        tokenFile = "/run/secrets/github/runner-token";

        # Runner identification
        name = "forge";
        labels = [
          "nixos"
          "homelab"
          "self-hosted"
        ];

        # Ephemeral mode: clean environment for each job
        ephemeral = true;

        # Single runner instance (increase if parallel jobs needed)
        count = 1;

        # Additional packages for CI jobs
        extraPackages = with pkgs; [
          # Task runner (used by this repo)
          go-task

          # Attic client (for when NAS-1 is ready)
          # attic-client

          # Additional utilities
          rsync
          openssh
        ];
      };
    }

    (lib.mkIf serviceEnabled {
      # WORKAROUND (2026-09-25): GitHub rejects the EOL channel's runner.
      # Affects: Forge's Actions runner; unstable requires Node 24 only.
      # Upstream: https://github.com/actions/runner/releases/tag/v2.337.0
      # Check: Remove when stable supplies a supported runner and matching runtimes.
      services.github-runners.forge = {
        package = pkgs.unstable.github-runner;
        nodeRuntimes = [ "node24" ];
      };

      # Service monitoring alert
      # GitHub runner is a systemd service, use systemd alert helper
      modules.alerting.rules."github-runner-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          "github-runner-forge"
          "GitHubRunner"
          "CI/CD self-hosted runner";
    })
  ];
}
