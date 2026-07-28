# Copyparty web file browser module
{ config, lib, mylib, pkgs, ... }:

let
  cfg = config.modules.services.copyparty;
  serviceIds = mylib.serviceUids.copyparty;
  sharedTypes = mylib.types;
  storageHelpers = mylib.storageHelpers pkgs;

  nfsMountConfig = storageHelpers.mkNfsMountConfig {
    inherit config;
    nfsMountDependency = cfg.nfsMountDependency;
  };
  nfsMountUnit =
    if nfsMountConfig == null then
      null
    else
      "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" nfsMountConfig.localPath)}.mount";

  volumePaths = builtins.attrValues cfg.readOnlyVolumes;
  volumeConfig = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (name: path: ''
      [/${name}]
        ${path}
        accs:
          r: @acct
        flags:
          d2t
          e2ds
          nohash: .
          nohtml
          scan: 900
          xvol
    '')
    cfg.readOnlyVolumes);

  configFile = pkgs.writeText "copyparty.conf" ''
    [global]
      i: ${cfg.listenAddress}
      p: ${toString cfg.port}
      hist: /var/cache/copyparty
      force-js
      idp-db: /var/cache/copyparty/idp.db
      idp-h-usr: X-Token-User-Email
      idp-store: 1
      no-crt
      no-dav
      no-logues
      no-readme
      no-reload
      no-robots
      rproxy: 1
      ses-db: /var/cache/copyparty/sessions.db
      vc-age: 3
      vc-exit
      vc-url: https://api.copyparty.eu/advisories
      xff-hdr: X-Forwarded-For
      xff-src: 127.0.0.1

    ${volumeConfig}
  '';
in
{
  options.modules.services.copyparty = {
    enable = lib.mkEnableOption "Copyparty web file browser";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.copyparty.override {
        withCertgen = false;
        withFTP = false;
        withFTPS = false;
        withHashedPasswords = false;
        withMediaProcessing = false;
        withSMB = false;
        withTFTP = false;
        withZeroMQ = false;
      };
      defaultText = lib.literalExpression "pkgs.copyparty.override { ... }";
      description = "Copyparty package with unused and higher-risk protocols removed";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address for the HTTP service to listen on";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3923;
      description = "Port for the Copyparty HTTP service";
    };

    readOnlyVolumes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { media = "/mnt/data/media"; };
      description = "Authenticated read-only URL volumes mapped to filesystem paths";
    };

    nfsMountDependency = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "media";
      description = "NFS mount name in modules.storage.nfsMounts required by this service";
    };

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Copyparty";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.readOnlyVolumes != { };
          message = "modules.services.copyparty.readOnlyVolumes must define at least one volume.";
        }
        {
          assertion = cfg.nfsMountDependency == null || nfsMountConfig != null;
          message = "Copyparty nfsMountDependency '${toString cfg.nfsMountDependency}' does not exist in modules.storage.nfsMounts.";
        }
        {
          assertion = config.users.groups ? media;
          message = "Copyparty requires the shared 'media' group.";
        }
        {
          assertion = lib.all (path: lib.hasPrefix "/" path) volumePaths;
          message = "All Copyparty readOnlyVolumes must use absolute paths.";
        }
      ];

      users.users.copyparty = {
        uid = serviceIds.uid;
        isSystemUser = true;
        group = serviceIds.groupName;
        description = serviceIds.description;
      };

      systemd.services.copyparty = {
        description = "Copyparty web file browser";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ] ++ lib.optional (nfsMountUnit != null) nfsMountUnit;
        requires = lib.optional (nfsMountUnit != null) nfsMountUnit;
        environment.PRTY_NO_TLS = "1";

        serviceConfig = {
          Type = "simple";
          ExecStart = "${lib.getExe cfg.package} -c ${configFile}";
          User = "copyparty";
          Group = serviceIds.groupName;
          Restart = "on-failure";
          RestartSec = "5s";

          RuntimeDirectory = "copyparty";
          RuntimeDirectoryMode = "0700";
          CacheDirectory = "copyparty";
          CacheDirectoryMode = "0700";
          WorkingDirectory = "/run/copyparty";
          UMask = "0077";

          BindReadOnlyPaths = [
            "/nix/store"
            "-/etc/group"
            "-/etc/hosts"
            "-/etc/localtime"
            "-/etc/nsswitch.conf"
            "-/etc/resolv.conf"
          ] ++ volumePaths;
          BindPaths = [
            "/run/copyparty"
            "/var/cache/copyparty"
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
