# Beszel server monitoring service module
#
# This module wraps the native NixOS Beszel service with homelab-specific patterns:
# - Hub: Web dashboard built on PocketBase for viewing connected systems
# - Agent: Runs on monitored systems to report metrics to the hub
# - ZFS storage integration for PocketBase persistence
# - Native OIDC support (configure via PocketBase UI after first deployment)
# - Caddy reverse proxy integration
# - Standard monitoring, backup, and alerting integrations
#
# Architecture: Beszel is a lightweight server monitoring platform with:
# - Docker/Podman container stats
# - Historical data with configurable retention
# - Alert functions (CPU, memory, disk, bandwidth, temperature)
# - Multi-user support with OAuth/OIDC
#
# Post-deployment: Configure OIDC in PocketBase UI at /_/#/settings
# See: https://pocket-id.org/docs/client-examples/beszel
#
{ config, lib, mylib, pkgs, ... }:

let
  cfg = config.modules.services.beszel;
  sharedTypes = mylib.types;

  # Import UIDs from centralized registry
  serviceIds = mylib.serviceUids;
  hubIds = serviceIds.beszel;
  agentIds = serviceIds.beszel-agent;

  # Hub configuration
  hubCfg = cfg.hub;
  hubServiceName = "beszel";

  # Agent configuration
  agentCfg = cfg.agent;
in
{
  options.modules.services.beszel = {
    # ==========================================================================
    # Hub Options
    # ==========================================================================
    hub = {
      enable = lib.mkEnableOption "Beszel monitoring hub";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.unstable.beszel;
        defaultText = lib.literalExpression "pkgs.unstable.beszel";
        description = "Beszel package to use";
      };

      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/beszel";
        description = "Directory for Beszel hub data (PocketBase database)";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8090;
        description = "Port for Beszel hub web interface";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Host address to bind to";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "beszel";
        description = "User account under which Beszel hub runs";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "beszel";
        description = "Group under which Beszel hub runs";
      };

      uid = lib.mkOption {
        type = lib.types.int;
        default = hubIds.uid;
        description = "UID for the Beszel service user (from lib/service-uids.nix)";
      };

      gid = lib.mkOption {
        type = lib.types.int;
        default = hubIds.gid;
        description = "GID for the Beszel service group (from lib/service-uids.nix)";
      };

      # Environment configuration
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Environment variables for Beszel hub";
        example = {
          DISABLE_PASSWORD_AUTH = "true";
          USER_CREATION = "true";
        };
      };

      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Environment file with secrets for Beszel hub";
      };

      # OIDC configuration hints (actual setup is in PocketBase UI)
      oidc = {
        enable = lib.mkEnableOption "OIDC authentication hints";

        disablePasswordAuth = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Disable password authentication (use OIDC only)";
        };

        userCreation = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Allow automatic user creation on first OIDC login";
        };
      };

      # Standardized integrations
      reverseProxy = lib.mkOption {
        type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
        default = null;
        description = "Reverse proxy configuration for Beszel hub";
      };

      metrics = lib.mkOption {
        type = lib.types.nullOr sharedTypes.metricsSubmodule;
        default = {
          enable = true;
          port = hubCfg.port;
          path = "/api/metrics";
          labels = {
            service = "beszel";
            service_type = "monitoring";
            function = "server_monitoring";
          };
        };
        description = "Prometheus metrics configuration";
      };

      backup = lib.mkOption {
        type = lib.types.nullOr sharedTypes.backupSubmodule;
        default = null;
        description = "Backup configuration for Beszel hub data";
      };

      preseed = lib.mkOption {
        type = lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "automatic restore before service start";

            repositoryUrl = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "URL to Restic repository for preseed restore";
            };

            passwordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Path to file containing Restic repository password";
            };

            restoreMethods = lib.mkOption {
              type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
              default = [ "syncoid" "local" ];
              description = "Ordered list of restore methods to attempt";
            };
          };
        };
        default = { };
        description = "Preseed/DR restore configuration";
      };
    };

    # ==========================================================================
    # Agent Options
    # ==========================================================================
    agent = {
      enable = lib.mkEnableOption "Beszel monitoring agent";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.unstable.beszel;
        defaultText = lib.literalExpression "pkgs.unstable.beszel";
        description = "Beszel package to use for agent";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 45876;
        description = "Port for Beszel agent to listen on";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "beszel-agent";
        description = "User account under which Beszel agent runs";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "beszel-agent";
        description = "Group under which Beszel agent runs";
      };

      uid = lib.mkOption {
        type = lib.types.int;
        default = agentIds.uid;
        description = "UID for the Beszel agent user (from lib/service-uids.nix)";
      };

      gid = lib.mkOption {
        type = lib.types.int;
        default = agentIds.gid;
        description = "GID for the Beszel agent group (from lib/service-uids.nix)";
      };

      # Key can be provided via file or environment
      keyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to file containing the public SSH key(s) for hub authentication.
          The key is provided by the hub when adding a new system.
        '';
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Environment variables for Beszel agent";
        example = {
          FILESYSTEM = "/dev/sda1";
          DOCKER_HOST = "unix:///var/run/podman/podman.sock";
        };
      };

      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Environment file with secrets for Beszel agent";
      };

      extraPath = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "Extra packages to add to agent PATH (e.g., for GPU monitoring)";
      };
    };
  };

  config = lib.mkMerge [
    # ==========================================================================
    # Hub Configuration
    # ==========================================================================
    (lib.mkIf hubCfg.enable {
      # Use native NixOS Beszel hub service
      services.beszel.hub = {
        enable = true;
        package = hubCfg.package;
        port = hubCfg.port;
        host = hubCfg.host;
        dataDir = hubCfg.dataDir;

        # Merge environment with OIDC settings
        environment = hubCfg.environment // lib.optionalAttrs hubCfg.oidc.enable {
          DISABLE_PASSWORD_AUTH = lib.boolToString hubCfg.oidc.disablePasswordAuth;
          USER_CREATION = lib.boolToString hubCfg.oidc.userCreation;
        };

        environmentFile = hubCfg.environmentFile;
      };

      # Override systemd service for ZFS integration and stable user
      # Use mkMerge to preserve ExecStart from native module
      systemd.services.beszel = {
        after = [ "local-fs.target" "zfs-mount.service" ];
        wants = [ "zfs-mount.service" ];

        serviceConfig = lib.mkMerge [
          {
            # Disable DynamicUser for persistent storage with stable UIDs
            DynamicUser = lib.mkForce false;
            User = lib.mkForce hubCfg.user;
            Group = lib.mkForce hubCfg.group;

            # Security hardening
            ReadWritePaths = [ hubCfg.dataDir ];
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
          }
        ];
      };

      # Create stable user/group
      users.users.${hubCfg.user} = {
        uid = hubCfg.uid;
        group = hubCfg.group;
        isSystemUser = true;
        home = lib.mkForce "/var/empty";
        description = "Beszel monitoring hub service user";
      };

      users.groups.${hubCfg.group} = {
        gid = hubCfg.gid;
      };

      # Caddy reverse proxy integration
      modules.services.caddy.virtualHosts.${hubServiceName} = lib.mkIf (hubCfg.reverseProxy != null && hubCfg.reverseProxy.enable) {
        enable = true;
        hostName = hubCfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = hubCfg.port;
        };
        caddySecurity = hubCfg.reverseProxy.caddySecurity or null;
        extraConfig = hubCfg.reverseProxy.extraConfig or "";
      };

      # Backup integration
      modules.backup.restic.jobs.${hubServiceName} = lib.mkIf (hubCfg.backup != null && hubCfg.backup.enable) {
        enable = true;
        paths = [ hubCfg.dataDir ];
        repository = hubCfg.backup.repository;
        tags = hubCfg.backup.tags or [ "monitoring" hubServiceName "pocketbase" ];
        useSnapshots = hubCfg.backup.useSnapshots or true;
        zfsDataset = hubCfg.backup.zfsDataset or null;
      };

      # Firewall - localhost only for hub (accessed via reverse proxy)
      networking.firewall.interfaces.lo.allowedTCPPorts = [ hubCfg.port ];
    })

    # ==========================================================================
    # Agent Configuration
    # ==========================================================================
    (lib.mkIf agentCfg.enable {
      # Use native NixOS Beszel agent service
      services.beszel.agent = {
        enable = true;
        package = agentCfg.package;

        # Agent connects to hub, so we configure listen port and key
        environment = {
          LISTEN = toString agentCfg.port;
        } // lib.optionalAttrs (agentCfg.keyFile != null) {
          KEY_FILE = agentCfg.keyFile;
        } // agentCfg.environment;

        environmentFile = agentCfg.environmentFile;
        extraPath = agentCfg.extraPath;
      };

      # Override systemd service to disable DynamicUser and use stable user
      systemd.services.beszel-agent = {
        serviceConfig = lib.mkMerge [
          {
            # Disable DynamicUser for stable UIDs and SOPS secret access
            DynamicUser = lib.mkForce false;
            User = lib.mkForce agentCfg.user;
            Group = lib.mkForce agentCfg.group;
          }
          # Add podman socket access if available
          (lib.mkIf config.virtualisation.podman.enable {
            SupplementaryGroups = [ "podman" ];
          })
        ];
      };

      # Create stable user/group for agent
      users.users.${agentCfg.user} = {
        uid = agentCfg.uid;
        group = agentCfg.group;
        isSystemUser = true;
        home = "/var/empty";
        description = "Beszel monitoring agent service user";
      };

      users.groups.${agentCfg.group} = {
        gid = agentCfg.gid;
      };

      # Open firewall for agent (hub connects to agent)
      networking.firewall.allowedTCPPorts = [ agentCfg.port ];
    })
  ];
}
