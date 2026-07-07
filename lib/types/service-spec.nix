# Service specification type for the factory pattern
#
# This is the SINGLE source of truth for the `spec` parameter passed to
# mkContainerService (lib/service-factory.nix). The schema is declared once
# (specOptions below) and enforced by validateServiceSpec, which catches typos
# and missing required fields at evaluation time rather than at runtime.
#
# CRITICAL: Without this validation, errors like `spec.zfsRecordsize` vs
# `spec.zfsRecordSize` would silently use null/default and only fail at deploy.
#
# NOTE (2026-07): the previously exported `serviceSpecSubmodule` duplicated
# this schema, had drifted (missing healthCommand/healthcheck/hasConfigGenerator),
# and had zero consumers. It was removed; validateServiceSpec's specOptions is
# now the only schema definition.

{ lib }:
let
  inherit (lib) types mkOption;

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

  # The service spec schema. All fields used by the factory must be declared
  # here — unknown fields are rejected by evalModules in validateServiceSpec.
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
    healthCommand = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Custom health check command (overrides default curl-based check)";
    };
    healthcheck = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          interval = mkOption { type = types.str; default = "30s"; };
          timeout = mkOption { type = types.str; default = "10s"; };
          retries = mkOption { type = types.int; default = 3; };
          startPeriod = mkOption { type = types.str; default = "300s"; };
          onFailure = mkOption { type = types.str; default = "kill"; };
        };
      });
      default = null;
      description = "Override healthcheck settings from spec (vs runtime cfg)";
    };
    metricsPath = mkOption { type = types.str; default = "/metrics"; };
    metricsEnable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether this service exposes a REAL Prometheus metrics endpoint.
        Defaults to false: most containerized apps (the *arr suite, download
        clients, ...) have no native /metrics endpoint, and auto-discovery
        must only scrape endpoints that actually speak the Prometheus
        exposition format. Set to true only for apps with native metrics
        (or a bundled exporter reachable at metricsPath on the service port).
      '';
    };
    startPeriod = mkOption { type = types.str; default = "120s"; };
    containerPort = mkOption { type = types.nullOr types.port; default = null; };
    backendScheme = mkOption { type = types.str; default = "http"; };
    environmentFiles = mkOption { type = types.listOf types.str; default = [ ]; };
    containerOverrides = mkOption { type = types.attrsOf types.anything; default = { }; };
    skipDefaultConfigMount = mkOption { type = types.bool; default = false; };
    runAsRoot = mkOption { type = types.bool; default = false; };
    hardening = mkOption {
      type = types.submodule {
        options = {
          allowPrivilegeEscalation = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Opt out of the default --security-opt=no-new-privileges.
              Only needed for images whose entrypoint relies on gaining
              privileges across execve (e.g. sudo invoked by a non-root
              user, or file capabilities). Plain privilege *dropping*
              (gosu/su-exec/s6-setuidgid from a root entrypoint) works
              fine under no-new-privileges and does not need this.
            '';
          };
          capAdd = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = ''
              Capabilities to add back for non-root containers that get
              --cap-drop=ALL by default (e.g. [ "NET_BIND_SERVICE" ]).
            '';
          };
        };
      };
      default = { };
      description = "Container hardening defaults for this service spec";
    };
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
in
{
  # Helper to validate a spec at evaluation time
  # Usage: validatedSpec = validateServiceSpec spec;
  # This function runs the spec through the module type checker
  validateServiceSpec = spec:
    let
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
