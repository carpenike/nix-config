# Custom Library Collection
#
# Aggregates all helper functions into a single, cohesive library that can be
# injected into the NixOS module system via _module.args.
#
# This provides clean, explicit imports without relative paths and makes all
# helpers available as first-class arguments in modules (like pkgs and lib).
#
# Usage in modules:
#   { config, lib, mylib, pkgs, ... }:
#   {
#     # Access shared types
#     someOption = lib.mkOption {
#       type = mylib.types.metricsSubmodule;
#     };
#
#     # Use monitoring helpers
#     modules.alerting.rules.my-service = [
#       (mylib.monitoring-helpers.mkServiceDownAlert { ... })
#     ];
#
#     # Use storage helpers (requires pkgs)
#     storageHelpers = mylib.storageHelpers pkgs;
#     replicationConfig = storageHelpers.mkReplicationConfig { ... };
#   }

{ lib }:

{
  # Shared type definitions for standardized service module patterns
  # Provides reusable submodule types (metrics, logging, backup, reverseProxy, etc.)
  types = import ./types.nix { inherit lib; };

  # Backup helper functions
  # Note: Currently deprecated - see file for migration details
  backup-helpers = import ./backup-helpers.nix { inherit lib; pkgs = null; };

  # Caddy reverse proxy configuration helpers
  caddy-helpers = import ./caddy-helpers.nix { inherit lib; };

  # DNS record management helpers
  dns = import ./dns.nix { inherit lib; };
  dns-aggregate = import ./dns-aggregate.nix { inherit lib; };

  # Virtual host registration helpers
  register-vhost = import ./register-vhost.nix { inherit lib; };

  # System builder (used in flake.nix)
  # Note: This is imported separately in flake.nix, not via this aggregation
  # mkSystem = import ./mkSystem.nix { inherit lib; };

  # Monitoring alert template helpers
  # Provides reusable functions for creating consistent Prometheus alert rules
  monitoring-helpers = import ./monitoring-helpers.nix { inherit lib; };

  # Storage helper functions for ZFS datasets, NFS mounts, and preseed services
  # Usage: storageHelpers = mylib.storageHelpers pkgs;
  # Functions: mkPreseedService, mkReplicationConfig, mkNfsMountConfig, etc.
  storageHelpers = pkgs: import ../modules/nixos/storage/helpers-lib.nix { inherit pkgs lib; };
}
