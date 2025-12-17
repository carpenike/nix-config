# Log shipping type definition (Promtail/Loki integration)
{ lib }:
let
  inherit (lib) types mkOption mkEnableOption;
in
{
  # Standardized logging collection submodule
  # Services that produce logs should use this type for automatic Promtail integration
  loggingSubmodule = types.submodule {
    options = {
      enable = mkEnableOption "log shipping to Loki";

      driver = mkOption {
        type = types.enum [ "journald" "json-file" "none" ];
        default = "journald";
        description = "Logging driver for container services";
      };

      logFiles = mkOption {
        type = types.listOf types.path;
        default = [ ];
        description = "Log files to ship to Loki";
        example = [ "/var/log/service.log" "/var/log/service-error.log" ];
      };

      journalUnit = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Systemd unit to collect journal logs from";
        example = "myservice.service";
      };

      labels = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Static labels to apply to log streams";
        example = {
          service = "myservice";
          environment = "production";
        };
      };

      parseFormat = mkOption {
        type = types.enum [ "json" "logfmt" "regex" "multiline" "none" ];
        default = "none";
        description = "Log parsing format for structured log extraction";
      };

      regexConfig = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Regex pattern for custom log parsing (when parseFormat = 'regex')";
      };

      multilineConfig = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            firstLineRegex = mkOption {
              type = types.str;
              description = "Regex to identify the first line of a multiline log entry";
            };
            maxWaitTime = mkOption {
              type = types.str;
              default = "3s";
              description = "Maximum time to wait for additional lines";
            };
          };
        });
        default = null;
        description = "Multiline log configuration (when parseFormat = 'multiline')";
      };
    };
  };
}
