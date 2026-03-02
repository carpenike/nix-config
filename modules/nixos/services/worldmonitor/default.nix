{ config, lib, pkgs, mylib, ... }:

let
  inherit (lib)
    mkIf
    mkMerge
    mkEnableOption
    mkOption
    types
    ;

  storageHelpers = mylib.storageHelpers pkgs;

  cfg = config.modules.services.worldmonitor;
  serviceIds = mylib.serviceUids.worldmonitor;

  serviceName = "worldmonitor";

  sharedTypes = mylib.types;

  storageCfg = config.modules.storage;
  datasetsCfg = storageCfg.datasets or { };

  wmDataset =
    if (datasetsCfg ? services) && ((datasetsCfg.services or { }) ? "${serviceName}") then
      datasetsCfg.services."${serviceName}"
    else
      null;

  defaultDataDir =
    if wmDataset != null then
      wmDataset.mountpoint or "/var/lib/${serviceName}"
    else
      "/var/lib/${serviceName}";

  defaultDatasetPath =
    if datasetsCfg ? parentDataset then
      "${datasetsCfg.parentDataset}/${serviceName}"
    else
      null;

in
{
  options.modules.services.worldmonitor = {
    enable = mkEnableOption "World Monitor - real-time global intelligence dashboard";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./package.nix { };
      description = "World Monitor package to run.";
    };

    user = mkOption {
      type = types.str;
      default = "worldmonitor";
      description = "System user for World Monitor.";
    };

    group = mkOption {
      type = types.str;
      default = "worldmonitor";
      description = "System group for World Monitor.";
    };

    dataDir = mkOption {
      type = types.path;
      default = defaultDataDir;
      description = "Directory for World Monitor persistent data (cache, state).";
    };

    datasetPath = mkOption {
      type = types.nullOr types.str;
      default = defaultDatasetPath;
      description = "ZFS dataset backing the data directory.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address for the API server.";
    };

    port = mkOption {
      type = types.port;
      default = 46123;
      description = "Port for the API server.";
    };

    frontendPort = mkOption {
      type = types.port;
      default = 46124;
      description = "Port for the static frontend server (served by a simple file server).";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to an environment file containing API keys.
        Use SOPS to manage this. Keys include:
          UPSTASH_REDIS_REST_URL, UPSTASH_REDIS_REST_TOKEN,
          GROQ_API_KEY, OLLAMA_API_URL, FRED_API_KEY,
          FINNHUB_API_KEY, NASA_FIRMS_API_KEY, etc.
      '';
    };

    cloudFallback = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to fall back to worldmonitor.app for API handlers that
        fail locally (missing API keys, etc.). Disable for fully air-gapped.
      '';
    };

    # ----- Reverse Proxy -----
    reverseProxy = {
      enable = mkEnableOption "Caddy reverse proxy for World Monitor";

      hostName = mkOption {
        type = types.str;
        default = "";
        description = "Public hostname for the reverse proxy (e.g., monitor.example.com).";
      };

      caddySecurity = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = ''
          Caddy security configuration (PocketID auth).
          Pass forgeDefaults.caddySecurity.admin or similar.
          The attrs are passed directly to the virtualHost's caddySecurity option
          AND used to generate auth routing in handle-only mode.
        '';
      };
    };

    # ----- Backup -----
    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration.";
    };

    # ----- Preseed (disaster recovery) -----
    preseed = {
      enable = mkEnableOption "automatic restore before service start";

      repositoryUrl = mkOption {
        type = types.str;
        default = "";
        description = "URL to Restic repository for preseed restore.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing the Restic repository password.";
      };

      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to environment file for remote repository credentials.";
      };

      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Ordered list of restore methods to try.";
      };
    };

    # ----- Notifications -----
    notifications = {
      enable = mkEnableOption "notifications for World Monitor";
    };

    # ----- LLM -----
    ollama = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to configure Ollama integration for AI features.";
      };

      url = mkOption {
        type = types.str;
        default = "http://127.0.0.1:11434";
        description = "Ollama API endpoint URL.";
      };

      model = mkOption {
        type = types.str;
        default = "llama3.1:8b";
        description = "Default Ollama model for summarization.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # ----- Core service -----
    {
      users.users.${cfg.user} = {
        uid = serviceIds.uid;
        group = cfg.group;
        isSystemUser = true;
        home = cfg.dataDir;
        description = "World Monitor service user";
      };

      users.groups.${cfg.group} = {
        gid = serviceIds.gid;
      };

      # API sidecar server
      systemd.services.worldmonitor-api = {
        description = "World Monitor API Server";
        after = [ "network-online.target" ] ++ lib.optional cfg.preseed.enable "preseed-worldmonitor.service";
        wants = [ "network-online.target" ] ++ lib.optional cfg.preseed.enable "preseed-worldmonitor.service";
        wantedBy = [ "multi-user.target" ];

        environment = {
          LOCAL_API_PORT = toString cfg.port;
          LOCAL_API_HOST = cfg.listenAddress;
          NODE_ENV = "production";
        } // lib.optionalAttrs cfg.ollama.enable {
          OLLAMA_API_URL = cfg.ollama.url;
          OLLAMA_MODEL = cfg.ollama.model;
        } // lib.optionalAttrs (!cfg.cloudFallback) {
          LOCAL_API_CLOUD_FALLBACK = "false";
        };

        serviceConfig = {
          Type = "simple";
          ExecStart = "${cfg.package}/bin/worldmonitor-api";
          WorkingDirectory = "${cfg.package}/share/worldmonitor";
          Restart = "on-failure";
          RestartSec = 5;
          User = cfg.user;
          Group = cfg.group;

          # Hardening
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          ReadWritePaths = [ cfg.dataDir ];
        } // lib.optionalAttrs (cfg.environmentFile != null) {
          EnvironmentFile = cfg.environmentFile;
        };
      };

      # Static frontend file server (using Python http.server or similar)
      # Caddy can serve this directly from the dist/ directory instead
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
      ];
    }

    # ----- Reverse Proxy -----
    (mkIf cfg.reverseProxy.enable (
      let
        caddySecCfg = cfg.reverseProxy.caddySecurity;
        useCaddySecurity = caddySecCfg != null && (caddySecCfg.enable or false);
        sanitizedHost = lib.replaceStrings [ "." "-" ] [ "_" "_" ] cfg.reverseProxy.hostName;

        # Generate caddySecurity authentication/authorization directives
        # for handle-only mode (the Caddy module skips these when handleOnly = true)
        caddySecurityDirectives = lib.optionalString useCaddySecurity ''
          @caddy_security_${sanitizedHost} {
            path /caddy-security/* /oauth2/*
          }

          route @caddy_security_${sanitizedHost} {
            authenticate with ${caddySecCfg.portal or "pocketid"}
          }
        '';

        # Core routing: API proxy + static file serving with SPA fallback
        coreRouting = ''
          handle /api/* {
            reverse_proxy ${cfg.listenAddress}:${toString cfg.port}
          }

          handle {
            root * ${cfg.package}/share/worldmonitor/dist

            # SPA fallback — serve index.html for all non-file routes
            try_files {path} /index.html
            file_server

            # Cache immutable assets
            @immutable path /assets/*
            header @immutable Cache-Control "public, max-age=31536000, immutable"

            # Don't cache the SPA shell
            @html path /index.html /
            header @html Cache-Control "no-cache, no-store, must-revalidate"
          }
        '';

        # When caddySecurity is enabled, wrap core routing in an authorized route
        routingBlock =
          if useCaddySecurity then ''
            route /* {
              authorize with ${caddySecCfg.policy or "default"}
            ${coreRouting}
            }
          '' else coreRouting;
      in
      {
        modules.services.caddy.virtualHosts.worldmonitor = {
          enable = true;
          handleOnly = true;
          hostName = cfg.reverseProxy.hostName;

          # Pass caddySecurity to the virtualHost for claim role registration
          # (the Caddy module collects these globally even in handleOnly mode)
          caddySecurity = caddySecCfg;

          extraConfig = caddySecurityDirectives + routingBlock;
        };
      }
    ))

    # ----- Preseed -----
    (mkIf cfg.preseed.enable (
      storageHelpers.mkPreseedService {
        serviceName = "worldmonitor";
        dataset = cfg.datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = "worldmonitor-api.service";
        replicationCfg = null;
        datasetProperties = {
          recordsize = "128K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ]);
}
