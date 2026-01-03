# TheLounge IRC client module
#
# Native NixOS service wrapper with homelab patterns:
# - ZFS storage integration for user data and logs
# - Caddy reverse proxy with PocketID authentication
# - Pre-configured IRC network defaults
# - Standard backup/preseed/monitoring integrations
#
# Architecture Decision: Uses native services.thelounge from nixpkgs,
# wrapped with homelab patterns (ZFS, backup, preseed, monitoring).
#
# Authentication: TheLounge supports "public mode" (`public = true`)
# which disables native authentication entirely. We use this combined
# with caddySecurity/PocketID for SSO access control.
#
# IRC Networks: TheLounge only supports ONE default network in config.js
# via the `defaults` object. Additional networks are per-user in their
# user.json files. Use `lockNetwork = true` to force the default network.
#
{ config, lib, mylib, ... }:

let
  cfg = config.modules.services.thelounge;
  serviceName = "thelounge";
  # Import service UIDs from centralized registry
  serviceIds = mylib.serviceUids.thelounge;

  # Import shared types for standard submodules
  sharedTypes = mylib.types;

  # IRC network defaults submodule
  ircNetworkSubmodule = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Display name for the network in TheLounge UI";
        example = "Libera.Chat";
      };

      host = lib.mkOption {
        type = lib.types.str;
        description = "IRC server hostname";
        example = "irc.libera.chat";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 6697;
        description = "IRC server port (6697 for TLS, 6667 for plain)";
      };

      tls = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use TLS encryption for IRC connection";
      };

      nick = lib.mkOption {
        type = lib.types.str;
        default = "thelounge";
        description = "Default nickname";
      };

      username = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Username/ident (optional)";
      };

      realname = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Real name/GECOS (optional)";
      };

      password = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Server or SASL password (optional)";
      };

      join = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Comma-separated list of channels to auto-join";
        example = "#thelounge,#libera";
      };

      lockNetwork = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Lock network settings (prevent users from changing host/port/TLS)";
      };
    };
  };

in
{
  options.modules.services.thelounge = {
    enable = lib.mkEnableOption "TheLounge IRC web client";

    user = lib.mkOption {
      type = lib.types.str;
      default = serviceName;
      description = "User account under which TheLounge runs";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = serviceName;
      description = "Group under which TheLounge runs";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = serviceIds.uid;
      description = "UID for TheLounge service user (from lib/service-uids.nix)";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = serviceIds.gid;
      description = "GID for TheLounge service group (from lib/service-uids.nix)";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/thelounge";
      description = "Path to TheLounge data directory";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9000;
      description = "Port for TheLounge web interface";
    };

    # Run in public mode (disables native authentication)
    # Use caddySecurity for access control instead
    public = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run TheLounge in public mode.
        When true, disables native authentication entirely.
        Use caddySecurity for access control via PocketID.
      '';
    };

    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "TheLounge plugins to install";
    };

    # Default IRC network configuration
    defaultNetwork = lib.mkOption {
      type = lib.types.nullOr ircNetworkSubmodule;
      default = null;
      description = ''
        Default IRC network shown in the Connect dialog.
        TheLounge only supports ONE default network in config.js.
        Use lockNetwork = true to prevent users from changing settings.
      '';
      example = lib.literalExpression ''
        {
          name = "Libera.Chat";
          host = "irc.libera.chat";
          port = 6697;
          tls = true;
          nick = "myNick";
          join = "#thelounge,#nixos";
          lockNetwork = false;
        }
      '';
    };

    # Additional config options passed to services.thelounge.extraConfig
    extraConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Additional TheLounge configuration options";
    };

    # =========================================================================
    # Standard Integration Submodules
    # =========================================================================

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for TheLounge web interface";
    };

    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = cfg.port;
        path = "/";
        labels = {
          service = serviceName;
          service_type = "communication";
          function = "irc_client";
        };
      };
      description = "Prometheus metrics configuration (TheLounge doesn't have native metrics, used for auto-discovery)";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration for TheLounge data";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "admin-alerts" ];
        };
        customMessages = {
          failure = "TheLounge IRC client failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for TheLounge service events";
    };

    # Preseed/DR capability
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

  config = lib.mkIf cfg.enable {
    # Use native NixOS TheLounge service
    services.thelounge = {
      enable = true;
      port = cfg.port;
      public = cfg.public;
      plugins = cfg.plugins;

      extraConfig = lib.mkMerge [
        # Default network configuration
        (lib.mkIf (cfg.defaultNetwork != null) {
          defaults = {
            inherit (cfg.defaultNetwork) name host port tls nick password join lockNetwork;
          } // lib.optionalAttrs (cfg.defaultNetwork.username != null) {
            username = cfg.defaultNetwork.username;
          } // lib.optionalAttrs (cfg.defaultNetwork.realname != null) {
            realname = cfg.defaultNetwork.realname;
          };
        })

        # Enable reverse proxy mode (trust X-Forwarded-* headers)
        (lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          reverseProxy = true;
        })

        # User-provided extra config
        cfg.extraConfig
      ];
    };

    # Override systemd service for ZFS integration and stable user
    systemd.services.thelounge = {
      # Wait for ZFS datasets
      after = [ "local-fs.target" "zfs-mount.service" ];
      wants = [ "zfs-mount.service" ];

      # Override DynamicUser for persistent storage with stable UID
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = cfg.user;
        Group = cfg.group;

        # Security hardening
        ReadWritePaths = [ cfg.dataDir ];
      };
    };

    # Create thelounge user/group with stable UID/GID
    # Use mkForce for description since native module also defines this user
    users.users.${cfg.user} = {
      isSystemUser = true;
      uid = cfg.uid;
      group = cfg.group;
      home = lib.mkForce "/var/empty";
      description = lib.mkForce "TheLounge IRC client service user";
    };

    users.groups.${cfg.group} = {
      gid = cfg.gid;
    };

    # Caddy reverse proxy integration
    modules.services.caddy.virtualHosts.${serviceName} = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;
      backend = cfg.reverseProxy.backend;
      caddySecurity = cfg.reverseProxy.caddySecurity or null;
      extraConfig = cfg.reverseProxy.extraConfig or "";
    };

    # Backup integration
    modules.backup.restic.jobs.${serviceName} = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
      enable = true;
      paths = [ cfg.dataDir ];
      repository = cfg.backup.repository;
      tags = cfg.backup.tags or [ "communication" serviceName "irc" ];
      useSnapshots = cfg.backup.useSnapshots or true;
      zfsDataset = cfg.backup.zfsDataset or null;
    };

    # Firewall - only allow localhost access (internal service behind reverse proxy)
    networking.firewall.interfaces.lo.allowedTCPPorts = [ cfg.port ];
  };
}
