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

          Note: when `startupRetries > 0` (default), the startup-phase healthcheck
          (--health-startup-*) is what actually gates "is the container ready",
          and `startPeriod` becomes a backstop. The startup healthcheck polls
          on `startupInterval` and only fails after `startupRetries` consecutive
          failures, eliminating the noisy transient-unit failures we used to
          see during nixos-rebuild switches when the regular --health-interval
          timer fired before the container's HTTP server was ready.
        '';
      };

      startupInterval = mkOption {
        type = types.str;
        default = "10s";
        description = ''
          Interval between startup-phase health checks (--health-startup-interval).
          Faster than the regular interval so the container is marked ready
          quickly once it's actually serving. Only used when startupRetries > 0.
        '';
      };

      startupRetries = mkOption {
        type = types.int;
        default = 30;
        description = ''
          Number of startup-phase health checks before declaring startup failed
          (--health-startup-retries). At the default startupInterval=10s, this
          allows up to 5 minutes for the container to come up cleanly without
          producing failed transient systemd-run units.

          Set to 0 to disable the startup-phase healthcheck and fall back to
          --health-start-period only (legacy behavior, produces noisy failed
          transient units during nixos-rebuild switches).
        '';
      };

      startupTimeout = mkOption {
        type = types.str;
        default = "5s";
        description = ''
          Timeout for each startup-phase health check (--health-startup-timeout).
          Shorter than the regular timeout because we're polling more often.
          Only used when startupRetries > 0.
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
