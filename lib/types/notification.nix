# Notification integration type definition
{ lib }:
let
  inherit (lib) types mkOption mkEnableOption;
in
{
  # Standardized notification integration submodule
  # Services should use this type for consistent alerting
  notificationSubmodule = types.submodule {
    options = {
      enable = mkEnableOption "notifications for this service";

      channels = mkOption {
        type = types.submodule {
          options = {
            onFailure = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Notification channels for service failures";
              example = [ "gotify-critical" "slack-alerts" ];
            };

            onSuccess = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Notification channels for successful operations";
            };

            onBackup = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Notification channels for backup events";
            };

            onHealthCheck = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Notification channels for health check failures";
            };
          };
        };
        default = { };
        description = "Notification channel assignments";
      };

      customMessages = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Custom message templates";
        example = {
          failure = "Service \${serviceName} failed on \${hostname}";
          success = "Service \${serviceName} completed successfully";
        };
      };

      escalation = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            afterMinutes = mkOption {
              type = types.int;
              default = 15;
              description = "Minutes before escalating to additional channels";
            };

            channels = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Additional channels for escalated alerts";
            };
          };
        });
        default = null;
        description = "Alert escalation configuration";
      };
    };
  };
}
