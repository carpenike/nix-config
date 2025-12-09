# Standardized Backup Integration for Service Modules
#
# This module provides a standardized way for services to integrate with the
# comprehensive backup system defined in hosts/_modules/nixos/backup.nix.
# Services can use the backupSubmodule type to define their backup requirements,
# and this module will automatically configure the appropriate backup jobs.
#
# Usage in service modules:
#   backup = lib.mkOption {
#     type = lib.types.nullOr sharedTypes.backupSubmodule;
#     default = {
#       enable = true;
#       repository = "primary";
#       frequency = "daily";
#       tags = [ "database" "critical" ];
#       preBackupScript = ''
#         pg_dump mydb > /var/backup/mydb.sql
#       '';
#     };
#   };
#
{ config, lib, ... }:
with lib;
let
  cfg = config.modules.services.backup-integration;

  # Collect all service backup configurations
  discoverServiceBackups = config:
    let
      # Extract all modules.services.* configurations
      allServices = config.modules.services or { };

      # Filter services that have backup enabled
      servicesWithBackup = lib.filterAttrs
        (_name: service:
          (service.backup or null) != null &&
          (service.backup.enable or false)
        )
        allServices;

      # Convert to backup job format
      backupJobs = mapAttrsToList
        (serviceName: service: {
          name = "service-${serviceName}";
          config = {
            enable = true;
            repository = service.backup.repository or cfg.defaultRepository;
            tags = [ serviceName ] ++ (service.backup.tags or [ ]);
            paths = service.backup.paths or [ "/var/lib/${serviceName}" ];
            excludePatterns = (service.backup.excludePatterns or [ ]) ++ cfg.globalExcludePatterns;
            preBackupScript = service.backup.preBackupScript or "";
            postBackupScript = service.backup.postBackupScript or "";

            # Note: Schedule and retention are configured globally in the backup module, not per-job
          };
        })
        servicesWithBackup;
    in
    builtins.listToAttrs (map (job: { name = job.name; value = job.config; }) backupJobs);

  # Generate discovered backup jobs
  discoveredBackupJobs = discoverServiceBackups config;
in
{
  options.modules.services.backup-integration = {
    enable = mkEnableOption "automatic service backup integration";

    autoDiscovery = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable automatic discovery of service backup configurations";
      };
    };

    defaultRepository = mkOption {
      type = types.str;
      default = "nas-primary";
      description = "Default repository for services that don't specify one";
    };

    globalExcludePatterns = mkOption {
      type = types.listOf types.str;
      default = [
        "**/.cache"
        "**/cache"
        "**/*.tmp"
        "**/*.log"
        "**/core"
        "**/*.pid"
        "**/lost+found"
      ];
      description = "Global exclude patterns applied to all service backups";
    };
  };

  config = mkIf cfg.enable {
    # Integrate discovered backup jobs with the main backup system
    modules.backup = {
      enable = mkDefault true;
      restic = {
        enable = mkDefault true;

        # Merge auto-discovered jobs with existing configuration
        jobs = mkMerge [
          # Add auto-discovered service backup jobs
          (mkIf cfg.autoDiscovery.enable discoveredBackupJobs)
        ];
      };

      # Enable monitoring for service backups
      monitoring = {
        enable = mkDefault true;
        prometheus.enable = mkDefault true;
      };
    };

    # Ensure backup system dependencies are available
    assertions = [
      {
        assertion = cfg.enable -> config.modules.backup.enable;
        message = "Backup integration requires the main backup system to be enabled";
      }
      {
        assertion = cfg.autoDiscovery.enable -> config.modules.backup.restic.enable;
        message = "Backup auto-discovery requires Restic backup to be enabled";
      }
    ] ++ (
      # Repository validation assertions - prevent build failures from missing repositories
      let
        allServices = config.modules.services or { };
        servicesWithBackup = lib.filterAttrs
          (_name: service:
            (service.backup or null) != null &&
              (service.backup.enable or false)
          )
          allServices;
      in
      mapAttrsToList
        (serviceName: service: {
          assertion =
            let
              repoName = service.backup.repository or cfg.defaultRepository;
            in
            hasAttr repoName (config.modules.backup.restic.repositories or { });
          message = ''
            Service '${serviceName}' references an unknown backup repository '${service.backup.repository or cfg.defaultRepository}'.
            Please define it in modules.backup.restic.repositories or update the service backup configuration.
            Available repositories: ${concatStringsSep ", " (attrNames (config.modules.backup.restic.repositories or {}))}
          '';
        })
        servicesWithBackup
    );
  };
}
