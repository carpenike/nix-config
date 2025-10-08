# NFS Mount Management Module
# Provides DRY-based centralized NFS mount configuration across multiple hosts
{
  config,
  lib,
  ...
}:
with lib;
let
  cfg = config.modules.filesystems.nfs;

  # Helper to build mount options list
  buildMountOptions = share: shareConfig:
    shareConfig.options ++
    (optional shareConfig.readOnly "ro") ++
    (optional shareConfig.lazy "x-systemd.automount") ++
    (optional shareConfig.lazy "noauto") ++
    (optional (!shareConfig.autoMount && !shareConfig.lazy) "noauto") ++
    (optional shareConfig.cache "fsc") ++
    (optional shareConfig.soft "soft") ++
    (optional (!shareConfig.soft) "hard");

  # Helper to determine if a share should be mounted
  shouldMountShare = shareName: shareConfig:
    shareConfig.enable &&
    (shareConfig.localPath != null) &&
    (shareConfig.hostFilter == [] || elem config.networking.hostName shareConfig.hostFilter);
in
{
  options.modules.filesystems.nfs = {
    enable = mkEnableOption "centralized NFS mount management";

    servers = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          address = mkOption {
            type = types.str;
            description = "NFS server hostname or IP address";
            example = "nas.holthome.net";
          };

          version = mkOption {
            type = types.enum [ "3" "4" "4.0" "4.1" "4.2" ];
            default = "4.2";
            description = "NFS protocol version";
          };

          defaultOptions = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Default mount options for this server";
          };
        };
      });
      default = {};
      description = "NFS server definitions";
      example = literalExpression ''
        {
          nas = {
            address = "nas.holthome.net";
            version = "4.2";
            defaultOptions = [ "rsize=131072" "wsize=131072" ];
          };
        }
      '';
    };

    shares = mkOption {
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to enable this share";
          };

          server = mkOption {
            type = types.str;
            description = "NFS server name (must match a key in modules.filesystems.nfs.servers)";
            example = "nas";
          };

          remotePath = mkOption {
            type = types.str;
            description = "Remote path on NFS server";
            example = "/export/media";
          };

          localPath = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Local mount point (null to skip mounting on this host)";
            example = "/mnt/media";
          };

          options = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Additional NFS mount options (merged with server defaults and profile options)";
            example = [ "ro" "noexec" ];
          };

          readOnly = mkOption {
            type = types.bool;
            default = false;
            description = "Mount share as read-only";
          };

          autoMount = mkOption {
            type = types.bool;
            default = true;
            description = "Mount share automatically at boot";
          };

          lazy = mkOption {
            type = types.bool;
            default = false;
            description = "Use systemd automount (mount on first access)";
          };

          soft = mkOption {
            type = types.bool;
            default = false;
            description = "Use soft mount (timeout on server unavailability) instead of hard mount";
          };

          cache = mkOption {
            type = types.bool;
            default = false;
            description = "Enable FS-Cache for local caching (requires cachefilesd)";
          };

          neededForBoot = mkOption {
            type = types.bool;
            default = false;
            description = "Mount is needed for boot (mounts early in boot process)";
          };

          hostFilter = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Only mount on these hostnames (empty list = mount on all hosts)";
            example = [ "workstation" "mediaserver" ];
          };

          description = mkOption {
            type = types.str;
            default = "NFS share ${name}";
            description = "Human-readable description of this share";
          };
        };
      }));
      default = {};
      description = "NFS share definitions";
      example = literalExpression ''
        {
          media = {
            server = "nas";
            remotePath = "/export/media";
            localPath = "/mnt/media";
            readOnly = true;
            lazy = true;
            description = "Media library (movies, TV shows, music)";
          };

          backups = {
            server = "nas";
            remotePath = "/export/backups";
            localPath = "/mnt/nas/backups";
            autoMount = false;
            description = "Backup storage";
          };
        }
      '';
    };

    profiles = {
      performance = mkOption {
        type = types.bool;
        default = false;
        description = "Enable high-performance NFS settings (large rsize/wsize, async)";
      };

      reliability = mkOption {
        type = types.bool;
        default = true;
        description = "Enable reliability-focused settings (hard mounts, intr, tcp)";
      };

      readonly = mkOption {
        type = types.bool;
        default = false;
        description = "Default all shares to read-only with security hardening";
      };

      homelab = mkOption {
        type = types.bool;
        default = true;
        description = "Homelab-optimized settings (balanced performance and reliability)";
      };
    };

    globalOptions = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Global mount options applied to all NFS mounts";
      example = [ "tcp" "intr" ];
    };

    createMountPoints = mkOption {
      type = types.bool;
      default = true;
      description = "Automatically create local mount point directories";
    };
  };

  config = mkIf cfg.enable {
    # Ensure NFS support is available
    boot.supportedFilesystems = [ "nfs" "nfs4" ];

    # Enable NFS client services
    services.rpcbind.enable = mkDefault true;

    # Optional: Enable FS-Cache if any share uses it
    services.cachefilesd.enable = mkIf (any (share: share.cache) (attrValues cfg.shares)) true;

    # Calculate profile-based options
    modules.filesystems.nfs.globalOptions = mkMerge [
      # Homelab profile (default balanced settings)
      (mkIf cfg.profiles.homelab [
        "tcp"
        "intr"
        "timeo=600"
        "retrans=2"
      ])

      # Performance profile (larger buffers, async)
      (mkIf cfg.profiles.performance [
        "rsize=262144"
        "wsize=262144"
        "async"
        "noatime"
      ])

      # Reliability profile (conservative, hard mounts)
      (mkIf cfg.profiles.reliability [
        "hard"
        "tcp"
        "intr"
        "rsize=65536"
        "wsize=65536"
      ])

      # Read-only profile (security hardening)
      (mkIf cfg.profiles.readonly [
        "ro"
        "noexec"
        "nosuid"
        "nodev"
      ])
    ];

    # Generate filesystem configurations for enabled shares
    fileSystems = mapAttrs' (shareName: shareConfig:
      let
        serverConfig = cfg.servers.${shareConfig.server};

        # Build complete options list
        allOptions =
          [ "nfsvers=${serverConfig.version}" ] ++
          serverConfig.defaultOptions ++
          cfg.globalOptions ++
          (buildMountOptions shareName shareConfig);
      in
      nameValuePair shareConfig.localPath (mkIf (shouldMountShare shareName shareConfig) {
        device = "${serverConfig.address}:${shareConfig.remotePath}";
        fsType = if (hasPrefix "4" serverConfig.version) then "nfs4" else "nfs";
        options = allOptions;
        neededForBoot = shareConfig.neededForBoot;
      })
    ) (filterAttrs (name: share: share.localPath != null) cfg.shares);

    # Create systemd automount units for lazy mounts
    systemd.automounts = mapAttrsToList (shareName: shareConfig:
      mkIf (shouldMountShare shareName shareConfig && shareConfig.lazy) {
        where = shareConfig.localPath;
        wantedBy = [ "multi-user.target" ];
        automountConfig = {
          TimeoutIdleSec = "600";
        };
      }
    ) cfg.shares;

    # Create mount point directories
    systemd.tmpfiles.rules = mkIf cfg.createMountPoints (
      mapAttrsToList (shareName: shareConfig:
        mkIf (shouldMountShare shareName shareConfig)
          "d ${shareConfig.localPath} 0755 root root -"
      ) cfg.shares
    );

    # Assertions to catch configuration errors
    assertions = [
      {
        assertion = all (share:
          hasAttr share.server cfg.servers
        ) (attrValues cfg.shares);
        message = "All NFS shares must reference a defined server in modules.filesystems.nfs.servers";
      }
      {
        assertion = all (share:
          share.localPath == null || hasPrefix "/" share.localPath
        ) (attrValues cfg.shares);
        message = "NFS share localPath must be an absolute path or null";
      }
      {
        assertion = all (share:
          hasPrefix "/" share.remotePath
        ) (attrValues cfg.shares);
        message = "NFS share remotePath must be an absolute path";
      }
      {
        assertion = !cfg.profiles.performance || !cfg.profiles.reliability;
        message = "Cannot enable both performance and reliability profiles simultaneously";
      }
    ];
  };
}
