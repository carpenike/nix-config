# FileBrowser Quantum web file browser
{ config, lib, mylib, pkgs, ... }:

let
  cfg = config.modules.services.filebrowserQuantum;
  serviceIds = mylib.serviceUids.filebrowser-quantum;
  sharedTypes = mylib.types;
  storageHelpers = mylib.storageHelpers pkgs;
  yamlFormat = pkgs.formats.yaml { };

  nfsMountConfig = storageHelpers.mkNfsMountConfig {
    inherit config;
    nfsMountDependency = cfg.nfsMountDependency;
  };
  nfsMountUnit =
    if nfsMountConfig == null then
      null
    else
      "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" nfsMountConfig.localPath)}.mount";

  startScript = pkgs.writeShellScript "filebrowser-quantum-start" ''
    ${lib.optionalString cfg.oidc.enable ''
      export FILEBROWSER_OIDC_CLIENT_SECRET="$(< "$CREDENTIALS_DIRECTORY/oidc-client-secret")"
    ''}
    exec ${lib.getExe cfg.package} -c ${configFile}
  '';

  configFile = yamlFormat.generate "filebrowser-quantum.yaml" {
    server = {
      port = cfg.port;
      listen = cfg.listenAddress;
      baseURL = "/";
      database = "/var/cache/filebrowser-quantum/filebrowser.sqlite";
      cacheDir = "/var/cache/filebrowser-quantum/cache";
      disableUpdateCheck = true;
      disableWebDAV = true;
      maxArchiveSize = 20;
      numImageProcessors = 2;
      indexSqlConfig = {
        batchSize = 1000;
        cacheSizeMB = 64;
        startupIntegrityCheck = "probe";
      };
      logging = [{
        levels = "info|warning|error";
        apiFilter = "^/health|^/favicon.ico|^/static";
      }];
      sources = [{
        path = cfg.sourcePath;
        name = cfg.sourceName;
        config = {
          defaultEnabled = true;
          private = true;
          readOnly = true;
        };
      }];
    } // lib.optionalAttrs (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      externalUrl = "https://${cfg.reverseProxy.hostName}";
    };

    auth = {
      tokenExpirationHours = 8;
      methods = {
        password.enabled = false;
        proxy.enabled = false;
      } // lib.optionalAttrs cfg.oidc.enable {
        oidc = {
          enabled = true;
          adminGroup = cfg.oidc.adminGroup;
          clientId = cfg.oidc.clientId;
          issuerUrl = cfg.oidc.issuerUrl;
          scopes = "openid email profile groups";
          userIdentifier = "email";
          groupsClaim = "groups";
          userGroups = cfg.oidc.userGroups;
        };
      };
    };

    frontend = {
      name = "Media Library";
      disableDefaultLinks = true;
      styling = {
        customCSS = ./holthome-library.css;
        disableEventThemes = true;
      };
    };

    userDefaults = {
      sidebar = {
        sticky = true;
        hideFiles = false;
      };
      listing = {
        viewMode = "grid";
        gallerySize = 4;
        quickDownload = true;
        singleClick = true;
      };
      preview = {
        image = true;
        video = true;
        audio = true;
        popup = true;
        folder = true;
        highQuality = true;
        motionVideoPreview = false;
      };
      ui = {
        darkMode = false;
        themeColor = "#087d73";
        locale = "en";
      };
      account = {
        loginMethod = if cfg.oidc.enable then "oidc" else "proxy";
        lockPassword = true;
        disableSettings = false;
        disableUpdateNotifications = true;
        permissions = {
          api = false;
          admin = false;
          modify = false;
          share = false;
          realtime = false;
          delete = false;
          create = false;
          download = true;
        };
      };
    };
  };
in
{
  options.modules.services.filebrowserQuantum = {
    enable = lib.mkEnableOption "FileBrowser Quantum web file browser";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.filebrowser-quantum;
      defaultText = lib.literalExpression "pkgs.filebrowser-quantum";
      description = "FileBrowser Quantum package to run";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address for the HTTP service to listen on";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3924;
      description = "Port for the FileBrowser Quantum HTTP service";
    };

    sourcePath = lib.mkOption {
      type = lib.types.str;
      description = "Read-only filesystem path exposed through FileBrowser Quantum";
    };

    sourceName = lib.mkOption {
      type = lib.types.str;
      default = "Media";
      description = "Display name for the configured source";
    };

    nfsMountDependency = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "media";
      description = "NFS mount name in modules.storage.nfsMounts required by this service";
    };

    oidc = {
      enable = lib.mkEnableOption "native OpenID Connect authentication";

      adminGroup = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "OpenID Connect group whose members receive administrator privileges";
      };

      clientId = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "OpenID Connect client ID";
      };

      clientSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "File containing the OpenID Connect client secret";
      };

      issuerUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "OpenID Connect issuer URL";
      };

      userGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "OIDC groups allowed to sign in";
      };
    };

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for FileBrowser Quantum";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = lib.hasPrefix "/" cfg.sourcePath;
          message = "modules.services.filebrowserQuantum.sourcePath must be absolute.";
        }
        {
          assertion = cfg.nfsMountDependency == null || nfsMountConfig != null;
          message = "FileBrowser Quantum nfsMountDependency '${toString cfg.nfsMountDependency}' does not exist in modules.storage.nfsMounts.";
        }
        {
          assertion = config.users.groups ? media;
          message = "FileBrowser Quantum requires the shared 'media' group.";
        }
        {
          assertion = !cfg.oidc.enable || cfg.oidc.clientId != "";
          message = "FileBrowser Quantum native OIDC requires oidc.clientId.";
        }
        {
          assertion = !cfg.oidc.enable || cfg.oidc.clientSecretFile != null;
          message = "FileBrowser Quantum native OIDC requires oidc.clientSecretFile.";
        }
        {
          assertion = !cfg.oidc.enable || cfg.oidc.issuerUrl != "";
          message = "FileBrowser Quantum native OIDC requires oidc.issuerUrl.";
        }
      ];

      users.users.filebrowser-quantum = {
        uid = serviceIds.uid;
        isSystemUser = true;
        group = serviceIds.groupName;
        description = serviceIds.description;
      };

      systemd.services.filebrowser-quantum = {
        description = "FileBrowser Quantum web file browser";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ] ++ lib.optional (nfsMountUnit != null) nfsMountUnit;
        requires = lib.optional (nfsMountUnit != null) nfsMountUnit;
        path = [ pkgs.ffmpeg-headless ];

        environment = {
          FILEBROWSER_FFMPEG_PATH = "${pkgs.ffmpeg-headless}/bin";
          HOME = "/var/cache/filebrowser-quantum";
          XDG_CACHE_HOME = "/var/cache/filebrowser-quantum/cache";
        };

        serviceConfig = {
          Type = "simple";
          ExecStart = startScript;
          User = "filebrowser-quantum";
          Group = serviceIds.groupName;
          Restart = "on-failure";
          RestartSec = "5s";

          RuntimeDirectory = "filebrowser-quantum";
          RuntimeDirectoryMode = "0700";
          CacheDirectory = "filebrowser-quantum";
          CacheDirectoryMode = "0700";
          WorkingDirectory = "/var/cache/filebrowser-quantum";
          UMask = "0077";

          BindReadOnlyPaths = [
            "/nix/store"
            "-/etc/group"
            "-/etc/hosts"
            "-/etc/localtime"
            "-/etc/nsswitch.conf"
            "-/etc/resolv.conf"
            cfg.sourcePath
          ];
          BindPaths = [
            "/run/filebrowser-quantum"
            "/var/cache/filebrowser-quantum"
          ];
          TemporaryFileSystem = "/:ro";

          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateMounts = true;
          PrivateTmp = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectProc = "invisible";
          ProtectSystem = "strict";
          ProcSubset = "pid";
          RemoveIPC = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
          LimitNOFILE = 8192;
          LoadCredential = lib.optional cfg.oidc.enable "oidc-client-secret:${cfg.oidc.clientSecretFile}";
        };
      };
    }

    (lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      modules.services.caddy.virtualHosts.${cfg.reverseProxy.hostName} = {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = lib.mkDefault {
          scheme = "http";
          host = cfg.listenAddress;
          port = cfg.port;
        };
        caddySecurity = cfg.reverseProxy.caddySecurity or null;
        security = lib.mkDefault {
          hsts.enable = true;
        };
      };
    })
  ]);
}
