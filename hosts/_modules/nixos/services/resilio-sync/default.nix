{ lib, config, pkgs, ... }:
let
  inherit
    (lib)
    mkEnableOption
    mkOption
    mkIf
    mkMerge
    types
    optional
    mkAfter
    ;

  cfg = config.modules.services.resilioSync;

  folderSubmodule = name: types.submodule ({ ... }:
    {
      options = {
        path = mkOption {
          type = types.str;
          description = "Absolute directory path that should be synchronized via Resilio.";
          example = "/data/cooklang/recipes";
        };

        secretFile = mkOption {
          type = types.str;
          description = ''
            Path to a file containing the Resilio secret for this folder.
            Use sops-nix or systemd LoadCredential to place the secret under /run/secrets.
          '';
          example = "/run/secrets/resilio/cooklang";
        };

        useRelayServer = mkOption {
          type = types.bool;
          default = false;
          description = "Enable Resilio relay server fallback (required for double NAT or CGNAT).";
        };

        useTracker = mkOption {
          type = types.bool;
          default = true;
          description = "Use public tracker infrastructure to discover peers.";
        };

        useDHT = mkOption {
          type = types.bool;
          default = false;
          description = "Enable distributed hash table discovery (disable for private links).";
        };

        searchLAN = mkOption {
          type = types.bool;
          default = true;
          description = "Automatically discover peers on the local network.";
        };

        useSyncTrash = mkOption {
          type = types.bool;
          default = true;
          description = "Keep removed files in the .Sync/Archive trash folder.";
        };

        knownHosts = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Explicit host:port entries for private mesh links.";
          example = [ "100.64.1.20:4444" "nas-1.holthome.net:4444" ];
        };

        group = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            POSIX group that owns the synchronized directory. The rslsync service user will
            automatically be added to this group for write access.
          '';
        };

        owner = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Optional owner enforced via tmpfiles when ensurePermissions = true.";
        };

        mode = mkOption {
          type = types.str;
          default = "2770";
          description = "Octal mode used when ensurePermissions = true (defaults to setgid group write).";
        };

        ensurePermissions = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Create the directory (if missing) and enforce owner/group/mode via systemd-tmpfiles.
            Useful for nested directories that are not managed by the storage module.
          '';
        };

        readOnly = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Set to true when this node should never push writes back upstream. The module uses it for
            documentation and to validate that tmpfiles-managed permissions do not grant group write access.
          '';
        };
      };
    }
  );

  foldersWithNames = lib.mapAttrsToList (name: folder: folder // { __name = name; }) cfg.folders;

  sharedFolders = map (folder: {
    directory = folder.path;
    secretFile = folder.secretFile;
    useRelayServer = folder.useRelayServer;
    useTracker = folder.useTracker;
    useDHT = folder.useDHT;
    searchLAN = folder.searchLAN;
    useSyncTrash = folder.useSyncTrash;
    knownHosts = folder.knownHosts;
  }) foldersWithNames;

  managedFolderGroups = lib.unique (builtins.filter (group: group != null && group != "")
    (map (folder: folder.group) foldersWithNames));

  tmpfilesRules = lib.concatMap (folder: optional folder.ensurePermissions
    ''d ${folder.path} ${folder.mode} ${folder.owner} ${folder.group} - -''
  ) foldersWithNames;

  hasGroupWrite = folder:
    let
      mode = folder.mode;
      len = lib.stringLength mode;
      idx = if len >= 2 then len - 2 else 0;
      digit = lib.substring idx 1 mode;
    in
    lib.elem digit [ "2" "3" "6" "7" ];

  folderAssertions = lib.concatMap (folder: [
    {
      assertion = lib.hasPrefix "/" folder.path;
      message = "Resilio folder '${folder.__name}' must use an absolute path.";
    }
    {
      assertion = lib.hasPrefix "/" folder.secretFile;
      message = "Resilio folder '${folder.__name}' secretFile must be an absolute path.";
    }
    {
      assertion = !(folder.ensurePermissions && folder.owner == null);
      message = "Resilio folder '${folder.__name}' enabled ensurePermissions but did not set owner.";
    }
    {
      assertion = !(folder.ensurePermissions && folder.group == null);
      message = "Resilio folder '${folder.__name}' enabled ensurePermissions but did not set group.";
    }
    {
      assertion = !(folder.readOnly && folder.ensurePermissions && hasGroupWrite folder);
      message = "Resilio folder '${folder.__name}' marked readOnly but tmpfiles mode still grants group write access.";
    }
  ]) foldersWithNames;

in
{
  options.modules.services.resilioSync = {
    enable = mkEnableOption "opinionated Resilio Sync configuration for service data replication";

    package = mkOption {
      type = types.package;
      default = pkgs.resilio-sync;
      description = "Resilio Sync package to use";
    };

    deviceName = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Device name advertised to other peers";
    };

    listeningPort = mkOption {
      type = types.port;
      default = 0;
      description = "Static listening port for peer connections (0 = random).";
    };

    storagePath = mkOption {
      type = types.str;
      default = "/var/lib/resilio-sync";
      description = "Resilio internal state directory.";
    };

    directoryRoot = mkOption {
      type = types.str;
      default = "";
      description = "Optional default directory root for Web UI folder picker (kept empty for headless mode).";
    };

    checkForUpdates = mkOption {
      type = types.bool;
      default = false;
      description = "Allow Resilio to check for upstream updates via the internet.";
    };

    useUpnp = mkOption {
      type = types.bool;
      default = false;
      description = "Expose listeningPort via UPnP on consumer routers (disabled by default).";
    };

    downloadLimit = mkOption {
      type = types.int;
      default = 0;
      description = "Download speed limit in KB/s (0 = unlimited).";
    };

    uploadLimit = mkOption {
      type = types.int;
      default = 0;
      description = "Upload speed limit in KB/s (0 = unlimited).";
    };

    encryptLAN = mkOption {
      type = types.bool;
      default = true;
      description = "Encrypt LAN traffic between peers.";
    };

    webUI = {
      enable = mkEnableOption "legacy Resilio Web UI access (discouraged unless absolutely required)";

      listenAddress = mkOption {
        type = types.str;
        default = "[::1]";
        description = "Address for binding the management UI.";
      };

      listenPort = mkOption {
        type = types.port;
        default = 9000;
        description = "Port for the management UI.";
      };

      username = mkOption {
        type = types.str;
        default = "admin";
        description = "Web UI username (stored in the Nix store).";
      };

      password = mkOption {
        type = types.str;
        default = "";
        description = ''
          Web UI password (stored in the Nix store). Prefer to keep Web UI disabled unless necessary.
        '';
      };
    };

    apiKey = mkOption {
      type = types.str;
      default = "";
      description = "Developer API key (optional).";
    };

    folders = mkOption {
      type = types.attrsOf (folderSubmodule "folder");
      default = {};
      description = "Declarative shared folder definitions keyed by service name.";
    };

    extraGroups = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional POSIX groups the rslsync user should join.";
    };

    afterUnits = mkOption {
      type = types.listOf types.str;
      default = [ "zfs-mount.service" "local-fs.target" ];
      description = "Additional systemd units Resilio must start after (ensures ZFS mounts are ready).";
    };

    wantUnits = mkOption {
      type = types.listOf types.str;
      default = [ "zfs-mount.service" ];
      description = "Systemd units Resilio should want for clean ordering.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.folders != {} || cfg.webUI.enable;
          message = "modules.services.resilioSync requires at least one folder or Web UI enabled.";
        }
      ] ++ folderAssertions;
    }
    {
      services.resilio = {
        enable = true;
        package = cfg.package;
        deviceName = cfg.deviceName;
        listeningPort = cfg.listeningPort;
        storagePath = cfg.storagePath;
        directoryRoot = cfg.directoryRoot;
        checkForUpdates = cfg.checkForUpdates;
        useUpnp = cfg.useUpnp;
        downloadLimit = cfg.downloadLimit;
        uploadLimit = cfg.uploadLimit;
        encryptLAN = cfg.encryptLAN;
        enableWebUI = cfg.webUI.enable;
        httpListenAddr = cfg.webUI.listenAddress;
        httpListenPort = cfg.webUI.listenPort;
        httpLogin = if cfg.webUI.enable then cfg.webUI.username else "";
        httpPass = if cfg.webUI.enable then cfg.webUI.password else "";
        apiKey = cfg.apiKey;
        sharedFolders = sharedFolders;
      };

      systemd.services.resilio.after = mkAfter cfg.afterUnits;
      systemd.services.resilio.wants = mkAfter cfg.wantUnits;

      users.users.rslsync.extraGroups = mkAfter (lib.unique (cfg.extraGroups ++ managedFolderGroups));

      systemd.tmpfiles.rules = tmpfilesRules;
    }
  ]);
}
