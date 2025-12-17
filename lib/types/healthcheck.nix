# Container healthcheck type definition
{ lib }:
let
  inherit (lib) types mkOption mkEnableOption;
in
{
  # Standardized container healthcheck submodule
  # Container services should use this type for consistent health monitoring
  healthcheckSubmodule = types.submodule {
    options = {
      enable = mkEnableOption "container health check";

      interval = mkOption {
        type = types.str;
        default = "30s";
        description = "Frequency of health checks";
      };

      timeout = mkOption {
        type = types.str;
        default = "10s";
        description = "Timeout for each health check";
      };

      retries = mkOption {
        type = types.int;
        default = 3;
        description = "Number of retries before marking as unhealthy";
      };

      startPeriod = mkOption {
        type = types.str;
        default = "300s";
        description = ''
          Grace period for the container to initialize before failures are counted.
          Allows time for DB migrations, preseed operations, and first-run initialization.
        '';
      };

      command = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Custom healthcheck command. If null, uses service-specific default.";
        example = "curl -f http://localhost:8080/health || exit 1";
      };

      onFailure = mkOption {
        type = types.enum [ "none" "kill" "restart" "stop" ];
        default = "kill";
        description = ''
          Action to take when the container becomes unhealthy.
          - "none": No action, just mark unhealthy (legacy behavior)
          - "kill": Kill the container with SIGKILL, allowing systemd to restart it
          - "restart": Podman restarts the container directly
          - "stop": Stop the container gracefully

          "kill" is recommended as it integrates well with systemd's restart policies,
          allowing proper restart counting and backoff behavior.
        '';
      };
    };
  };
}
