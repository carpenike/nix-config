# Container resource management type definition
{ lib }:
let
  inherit (lib) types mkOption;
in
{
  # Standardized container resource management submodule
  # Containerized services should use this type for consistent resource limits
  containerResourcesSubmodule = types.submodule {
    options = {
      memory = mkOption {
        type = types.str;
        description = "Memory limit (e.g., '256m', '2g')";
        example = "512m";
      };

      memoryReservation = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Memory soft limit/reservation";
        example = "256m";
      };

      cpus = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "CPU limit in cores (e.g., '0.5' for half a core, '2' for 2 cores). Use this for podman containers.";
        example = "1.0";
      };

      cpuQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "CPU quota percentage for systemd services (e.g., '50%'). NOT used by podman containers - use cpus instead.";
        example = "75%";
      };

      oomKillDisable = mkOption {
        type = types.bool;
        default = false;
        description = "Disable OOM killer for this container";
      };

      swap = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Swap limit (e.g., '512m')";
      };
    };
  };
}
