# Service specification type for the factory pattern
#
# This type validates the `spec` parameter passed to mkContainerService,
# catching typos and missing required fields at evaluation time rather than
# at runtime.
#
# CRITICAL: Without this validation, errors like `spec.zfsRecordsize` vs
# `spec.zfsRecordSize` would silently use null/default and only fail at deploy.

{ lib }:
let
  inherit (lib) types mkOption literalExpression;

  # Valid service categories
  categoryEnum = types.enum [
    "media"
    "productivity"
    "infrastructure"
    "home-automation"
    "downloads"
    "monitoring"
    "ai"
  ];
in
{
  # Service specification submodule for mkContainerService
  # All fields used by the factory should be declared here
  serviceSpecSubmodule = types.submodule {
    options = {
      # Required fields
      port = mkOption {
        type = types.port;
        description = "Primary port for the service web interface";
        example = 8989;
      };

      image = mkOption {
        type = types.str;
        description = "Container image for the service. Use full path with registry.";
        example = "ghcr.io/home-operations/sonarr:rolling";
      };

      category = mkOption {
        type = categoryEnum;
        description = "Service category determining defaults for alerts, networking, and backup tags";
        example = "media";
      };

      # Optional fields with sensible defaults
      description = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Human-readable description of the service";
        example = "TV series collection manager";
      };

      displayName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Display name for notifications and alerts. Defaults to service name.";
        example = "Sonarr";
      };

      function = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Functional role for metrics labeling. Defaults to service name.";
        example = "tv-management";
      };

      # Web UI configuration
      webUI = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this service has a web UI requiring reverse proxy";
      };

      healthEndpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "HTTP endpoint for health checks. If null, uses TCP port check.";
        example = "/ping";
      };

      metricsPath = mkOption {
        type = types.str;
        default = "/metrics";
        description = "Path to Prometheus metrics endpoint";
      };

      # Container configuration
      startPeriod = mkOption {
        type = types.str;
        default = "120s";
        description = "Grace period for container initialization before healthchecks count";
      };

      containerPort = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Internal container port if different from host port. Defaults to service port.";
      };

      backendScheme = mkOption {
        type = types.str;
        default = "http";
        description = "Scheme for reverse proxy backend (http or https)";
      };

      environmentFiles = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Environment files to pass to container";
      };

      containerOverrides = mkOption {
        type = types.attrsOf types.anything;
        default = { };
        description = "Additional overrides to merge into container definition";
      };

      skipDefaultConfigMount = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to skip the default dataDir:/config volume mount.
          Set to true for services that don't use the /config convention.
        '';
      };

      resources = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            memory = mkOption {
              type = types.str;
              default = "512M";
              description = "Memory limit";
            };
            memoryReservation = mkOption {
              type = types.str;
              default = "256M";
              description = "Memory reservation (soft limit)";
            };
            cpus = mkOption {
              type = types.str;
              default = "1.0";
              description = "CPU limit";
            };
          };
        });
        default = null;
        description = "Container resource limits. If null, uses category defaults.";
      };

      # Storage configuration
      zfsRecordSize = mkOption {
        type = types.str;
        default = "128K";
        description = "ZFS recordsize for service dataset. Use 16K for databases, 1M for media.";
        example = "16K";
      };

      zfsCompression = mkOption {
        type = types.str;
        default = "zstd";
        description = "ZFS compression algorithm for service dataset";
        example = "lz4";
      };

      zfsProperties = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Additional ZFS properties for service dataset";
        example = literalExpression ''{ "com.sun:auto-snapshot" = "false"; }'';
      };

      useZfsSnapshots = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to use ZFS snapshots for backup consistency";
      };

      backupExcludePatterns = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional patterns to exclude from backup";
        example = [ "**/transcode/**" "**/Backups/**" ];
      };

      # Dynamic configuration functions
      # These are functions that receive cfg and return values
      environment = mkOption {
        type = types.nullOr (types.functionTo (types.attrsOf types.str));
        default = null;
        description = ''
          Function that receives cfg and returns environment variables.
          Example: cfg: { MY_VAR = if cfg.usesExternalAuth then "yes" else "no"; }
        '';
        example = literalExpression ''
          cfg: {
            SONARR__AUTH__METHOD = if cfg.usesExternalAuth then "External" else "None";
          }
        '';
      };

      volumes = mkOption {
        type = types.nullOr (types.functionTo (types.listOf types.str));
        default = null;
        description = ''
          Function that receives cfg and returns additional volume mounts.
          Example: cfg: [ "''${cfg.mediaDir}:/data:rw" ]
        '';
        example = literalExpression ''
          cfg: [
            "''${cfg.mediaDir}:/data:rw"
          ]
        '';
      };

      extraOptions = mkOption {
        type = types.nullOr (types.functionTo (types.listOf types.str));
        default = null;
        description = ''
          Function that receives cfg and returns additional podman run options.
          Example: cfg: [ "--group-add=''${toString config.users.groups.media.gid}" ]
        '';
        example = literalExpression ''
          cfg: [
            "--group-add=''${toString config.users.groups.media.gid}"
          ]
        '';
      };

      labels = mkOption {
        type = types.nullOr (types.functionTo (types.attrsOf types.str));
        default = null;
        description = ''
          Function that receives cfg and returns container labels.
          Example: cfg: { "traefik.enable" = "true"; }
        '';
      };
    };
  };

  # Helper to validate a spec at evaluation time
  # Usage: validatedSpec = validateServiceSpec spec;
  # This function runs the spec through the module type checker
  validateServiceSpec = spec:
    let
      # Define options directly (not via getSubOptions to avoid _module conflicts)
      specOptions = {
        # Required fields
        port = mkOption {
          type = types.port;
          description = "Primary port for the service web interface";
        };
        image = mkOption {
          type = types.str;
          description = "Container image for the service";
        };
        category = mkOption {
          type = categoryEnum;
          description = "Service category determining defaults";
        };
        # Optional fields with defaults
        description = mkOption { type = types.nullOr types.str; default = null; };
        displayName = mkOption { type = types.nullOr types.str; default = null; };
        function = mkOption { type = types.nullOr types.str; default = null; };
        webUI = mkOption { type = types.bool; default = true; };
        healthEndpoint = mkOption { type = types.nullOr types.str; default = null; };
        metricsPath = mkOption { type = types.str; default = "/metrics"; };
        startPeriod = mkOption { type = types.str; default = "120s"; };
        containerPort = mkOption { type = types.nullOr types.port; default = null; };
        backendScheme = mkOption { type = types.str; default = "http"; };
        environmentFiles = mkOption { type = types.listOf types.str; default = [ ]; };
        containerOverrides = mkOption { type = types.attrsOf types.anything; default = { }; };
        skipDefaultConfigMount = mkOption { type = types.bool; default = false; };
        resources = mkOption { type = types.nullOr (types.attrsOf types.str); default = null; };
        zfsRecordSize = mkOption { type = types.str; default = "128K"; };
        zfsCompression = mkOption { type = types.str; default = "zstd"; };
        zfsProperties = mkOption { type = types.attrsOf types.str; default = { }; };
        useZfsSnapshots = mkOption { type = types.bool; default = true; };
        backupExcludePatterns = mkOption { type = types.listOf types.str; default = [ ]; };
        hasConfigGenerator = mkOption { type = types.bool; default = false; };
        environment = mkOption { type = types.nullOr (types.functionTo (types.attrsOf types.str)); default = null; };
        volumes = mkOption { type = types.nullOr (types.functionTo (types.listOf types.str)); default = null; };
        extraOptions = mkOption { type = types.nullOr (types.functionTo (types.listOf types.str)); default = null; };
        labels = mkOption { type = types.nullOr (types.functionTo (types.attrsOf types.str)); default = null; };
      };

      # Evaluate the spec through the module system
      evaluated = lib.evalModules {
        modules = [
          { options = specOptions; }
          { config = spec; }
        ];
      };
    in
    evaluated.config;
}
