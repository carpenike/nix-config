# Systemd resource management type definition
{ lib }:
let
  inherit (lib) types mkOption;
in
{
  # Standardized systemd resource management submodule
  # Native systemd services should use this type for consistent resource limits
  systemdResourcesSubmodule = types.submodule {
    options = {
      MemoryMax = mkOption {
        type = types.str;
        description = "Maximum memory usage (systemd directive)";
        example = "1G";
      };

      MemoryReservation = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Memory soft limit/reservation (systemd directive)";
        example = "512M";
      };

      CPUQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "CPU quota percentage (systemd directive)";
        example = "50%";
      };

      CPUWeight = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "CPU scheduling weight (systemd directive)";
        example = 100;
      };

      IOWeight = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "IO scheduling weight (systemd directive)";
        example = 100;
      };
    };
  };
}
