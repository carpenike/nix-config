# Shared type definitions for service modules
#
# This module provides standardized submodule types for consistent
# service configuration across the infrastructure. Services import these
# types via `mylib.types` to ensure consistent option interfaces.
#
# ARCHITECTURE:
# - Each type is defined in its own focused file for maintainability
# - This file re-exports all types as a single attribute set
# - Import via: sharedTypes = mylib.types;
#
# AVAILABLE TYPES:
# - metricsSubmodule       - Prometheus metrics collection
# - loggingSubmodule       - Log shipping configuration (Promtail/Loki)
# - reverseProxySubmodule  - Caddy reverse proxy integration
# - backupSubmodule        - Restic backup configuration
# - notificationSubmodule  - Alert notification channels
# - datasetSubmodule       - ZFS dataset configuration
# - healthcheckSubmodule   - Container healthcheck configuration
# - containerResourcesSubmodule - Container resource limits
# - systemdResourcesSubmodule   - Systemd service resource limits
# - staticApiKeySubmodule       - API key authentication
#
# USAGE EXAMPLE:
#   { lib, mylib, ... }:
#   let
#     sharedTypes = mylib.types;
#   in {
#     options.modules.services.myservice = {
#       metrics = lib.mkOption {
#         type = lib.types.nullOr sharedTypes.metricsSubmodule;
#         default = null;
#       };
#     };
#   }

{ lib }:
let
  # Import all type modules
  metricsTypes = import ./metrics.nix { inherit lib; };
  loggingTypes = import ./logging.nix { inherit lib; };
  storageTypes = import ./storage.nix { inherit lib; };
  healthcheckTypes = import ./healthcheck.nix { inherit lib; };
  reverseProxyTypes = import ./reverse-proxy.nix { inherit lib; };
  backupTypes = import ./backup.nix { inherit lib; };
  notificationTypes = import ./notification.nix { inherit lib; };
  containerTypes = import ./container.nix { inherit lib; };
  resourcesTypes = import ./resources.nix { inherit lib; };
  authTypes = import ./auth.nix { inherit lib; };
in
{
  # Re-export all types from their respective modules
  inherit (metricsTypes) metricsSubmodule;
  inherit (loggingTypes) loggingSubmodule;
  inherit (storageTypes) datasetSubmodule;
  inherit (healthcheckTypes) healthcheckSubmodule;
  inherit (reverseProxyTypes) reverseProxySubmodule;
  inherit (backupTypes) backupSubmodule;
  inherit (notificationTypes) notificationSubmodule;
  inherit (containerTypes) containerResourcesSubmodule;
  inherit (resourcesTypes) systemdResourcesSubmodule;
  inherit (authTypes) staticApiKeySubmodule;
}
