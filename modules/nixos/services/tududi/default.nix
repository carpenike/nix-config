# modules/nixos/services/tududi-factory/default.nix
#
# Tududi - Personal task management application
# Factory-based implementation: ~115 lines vs 433 lines (73% reduction)
#
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "tududi";
  description = "Personal task management application";

  spec = {
    port = 3005;
    containerPort = 3002;
    image = "chrisvel/tududi:0.88.5@sha256:d027b5ab6fa5067ba1d42d11e24d4d22f84e1b04f68c99ec49567cc5e2167727";
    category = "productivity";

    displayName = "Tududi";
    function = "task_management";
    healthEndpoint = "/api/health";
    healthCommand = "wget -q --spider http://127.0.0.1:3002/api/health";
    metricsPath = "/";

    # Match upstream healthcheck settings
    healthcheck = {
      interval = "60s";
      timeout = "3s";
      retries = 2;
      startPeriod = "10s";
    };

    zfsRecordSize = "16K";
    zfsCompression = "lz4";
    useZfsSnapshots = true;
    skipDefaultConfigMount = true;
    runAsRoot = true; # Container entrypoint needs to chown files before dropping privileges

    resources = {
      memory = "512M";
      memoryReservation = "256M";
      cpus = "1.0";
    };

    environmentFiles = [ "/run/tududi/env" ];

    environment = { cfg, ... }: {
      TUDUDI_USER_EMAIL = cfg.adminEmail;
      TUDUDI_UPLOAD_PATH = "/app/backend/uploads";
    } // lib.optionalAttrs (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      TUDUDI_ALLOWED_ORIGINS = "https://${cfg.reverseProxy.hostName}";
    };

    volumes = cfg: [
      "${cfg.dataDir}/db:/app/backend/db:rw,Z"
      "${cfg.dataDir}/uploads:/app/backend/uploads:rw,Z"
    ];
  };

  extraOptions = {
    adminEmail = lib.mkOption {
      type = lib.types.str;
      default = "ryan@ryanholt.net";
      description = "Initial admin user email address";
    };

    adminPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to SOPS secret for initial admin password";
    };

    sessionSecretFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to SOPS secret for session secret";
    };
  };

  extraConfig = cfg: {
    assertions = [
      {
        assertion = builtins.isPath cfg.adminPasswordFile || builtins.isString cfg.adminPasswordFile;
        message = "Tududi adminPasswordFile must reference a SOPS secret.";
      }
      {
        assertion = builtins.isPath cfg.sessionSecretFile || builtins.isString cfg.sessionSecretFile;
        message = "Tududi sessionSecretFile must reference a SOPS secret.";
      }
    ];

    systemd.services."podman-tududi" = {
      serviceConfig.LoadCredential = [
        "admin_password:${cfg.adminPasswordFile}"
        "session_secret:${cfg.sessionSecretFile}"
      ];

      preStart = lib.mkAfter ''
        set -euo pipefail
        mkdir -p /run/tududi
        chmod 700 /run/tududi
        {
          printf "TUDUDI_USER_PASSWORD=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/admin_password")"
          printf "TUDUDI_SESSION_SECRET=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/session_secret")"
        } > /run/tududi/env
        chmod 600 /run/tududi/env
        mkdir -p ${cfg.dataDir}/db ${cfg.dataDir}/uploads
        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}
        chmod 750 ${cfg.dataDir}/db ${cfg.dataDir}/uploads
      '';
    };
  };
}
