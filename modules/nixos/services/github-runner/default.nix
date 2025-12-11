# GitHub Actions Runner service module
#
# This module wraps the native NixOS GitHub Actions runner with homelab-specific patterns:
# - SOPS-managed token integration
# - Ephemeral runner mode (clean state per job)
# - Pre-configured Nix environment with caching tools
# - Standard monitoring and alerting integration
#
# Architecture Decision: Uses native NixOS module (services.github-runners)
# per ADR-005 (native services over containers).
#
# Usage:
#   modules.services.github-runner = {
#     enable = true;
#     url = "https://github.com/carpenike/nix-config";
#     tokenFile = config.sops.secrets."github/runner-token".path;
#   };
#
{ config, lib, pkgs, mylib, ... }:

let
  cfg = config.modules.services.github-runner;

  # Import shared types for standard submodules
  sharedTypes = mylib.types;
in
{
  options.modules.services.github-runner = {
    enable = lib.mkEnableOption "GitHub Actions self-hosted runner";

    name = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Runner name (defaults to hostname)";
      example = "forge";
    };

    url = lib.mkOption {
      type = lib.types.str;
      description = ''
        Repository or organization URL to register the runner with.
        For org-wide tokens, use the org URL (e.g., https://github.com/myorg).
        For repo-specific tokens, use the repo URL.
      '';
      example = "https://github.com/carpenike/nix-config";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to file containing GitHub token.
        Recommended: Fine-grained PAT with "Read and Write access to self-hosted runners".
        The file should contain exactly one line with the token (no newline).
      '';
      example = "/run/secrets/github/runner-token";
    };

    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "nixos" "homelab" ];
      description = "Additional labels for the runner";
      example = [ "nixos" "homelab" "x86_64-linux" ];
    };

    count = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Number of runner instances to spawn";
      example = 2;
    };

    ephemeral = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run in ephemeral mode. When enabled:
        - Runner de-registers after processing one job
        - State directory is wiped on restart
        - Provides clean environment for each job
        Requires a PAT (not registration token) for automatic re-registration.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional packages to make available to the runner";
      example = lib.literalExpression "[ pkgs.docker ]";
    };

    # Standard monitoring integration
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = null;
      description = "Notification configuration for service failures";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create runner instances
    # Using a for loop to support multiple runners if count > 1
    services.github-runners = lib.listToAttrs (
      lib.genList
        (i:
          let
            runnerName =
              if cfg.count == 1
              then cfg.name
              else "${cfg.name}-${toString (i + 1)}";
          in
          lib.nameValuePair runnerName {
            enable = true;
            url = cfg.url;
            tokenFile = cfg.tokenFile;
            name = runnerName;
            replace = true;
            ephemeral = cfg.ephemeral;

            # Labels for workflow targeting
            extraLabels = cfg.labels ++ [
              pkgs.stdenv.hostPlatform.system # e.g., "x86_64-linux"
            ];

            # Packages available to the runner during job execution
            extraPackages = with pkgs; [
              # Core tools
              git
              bash
              coreutils
              gnused
              gnugrep
              gawk
              findutils

              # Nix ecosystem
              nix
              nixos-rebuild
              cachix

              # Build tools
              gnumake
              jq
              yq-go

              # Networking (for health checks, downloads)
              curl
              wget
            ] ++ cfg.extraPackages;

            # Environment variables for Nix
            extraEnvironment = {
              # Trust the flake config
              NIX_CONFIG = "accept-flake-config = true";
              # Ensure Nix uses the system's store
              HOME = "/var/lib/github-runner/${runnerName}";
            };

            # Service hardening
            serviceOverrides = {
              # Allow network access
              PrivateNetwork = false;

              # Limit capabilities
              NoNewPrivileges = true;
              ProtectSystem = "strict";
              ProtectHome = "read-only";

              # Allow writing to build directories
              ReadWritePaths = [
                "/nix/var/nix"
                "/tmp"
                "/var/lib/github-runner"
              ];
            };
          }
        )
        cfg.count
    );

    # Ensure the runner working directory exists with correct permissions
    systemd.tmpfiles.rules = [
      "d /var/lib/github-runner 0755 root root -"
    ];

    # Firewall: runners don't need inbound access (they poll GitHub)
    # No firewall rules needed

    # Assertions
    assertions = [
      {
        assertion = cfg.url != "";
        message = "modules.services.github-runner.url must be set";
      }
    ];
  };
}
