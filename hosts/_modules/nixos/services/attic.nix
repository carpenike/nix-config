# Attic Binary Cache Server Configuration
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.services.attic;
in
{
  options.modules.services.attic = {
    enable = lib.mkEnableOption "Attic binary cache server";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:8080";
      description = "Address for Attic server to listen on";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/atticd";
      description = "Directory for Attic data";
    };

    storageType = lib.mkOption {
      type = lib.types.enum [ "local" "s3" ];
      default = "local";
      description = "Storage backend for cache artifacts";
    };

    storageConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Storage-specific configuration";
    };

    jwtSecretFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the JWT HMAC secret (base64 encoded)";
    };

    reverseProxy = {
      enable = lib.mkEnableOption "Caddy reverse proxy for Attic";

      virtualHost = lib.mkOption {
        type = lib.types.str;
        description = "Virtual host for reverse proxy";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Create attic user and group
    users.users.attic = {
      description = "Attic binary cache server";
      group = "attic";
      home = cfg.dataDir;
      createHome = true;
      isSystemUser = true;
    };

    users.groups.attic = {};

    # Attic server configuration
    environment.etc."atticd/config.toml".text = ''
      # Attic Server Configuration

      listen = "${cfg.listenAddress}"

      [database]
      url = "sqlite://${cfg.dataDir}/server.db"

      [storage]
      type = "${cfg.storageType}"
      ${lib.optionalString (cfg.storageType == "local") ''
      path = "${cfg.dataDir}/storage"
      ''}
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k} = \"${v}\"") cfg.storageConfig)}

      [chunking]
      # NAR files are uploaded in chunks
      # This is the target chunk size for new uploads, in bytes
      nar-size-threshold = 65536    # 64 KiB

      # The minimum NAR size to trigger chunking
      # If 0, chunking is disabled entirely for new uploads.
      # If 1, all new uploads are chunked.
      min-size = 1048576            # 1 MiB

      # The preferred chunk size, in bytes
      avg-size = 65536              # 64 KiB

      # The maximum chunk size, in bytes
      max-size = 262144             # 256 KiB

      [compression]
      # Compression type: "none", "brotli", "gzip", "xz", "zstd"
      type = "zstd"
      level = 8
    '';

    # Create storage directory if using local storage
    systemd.tmpfiles.rules = lib.optionals (cfg.storageType == "local") [
      "d ${cfg.dataDir}/storage 755 attic attic -"
    ];

    # Attic server service
    systemd.services.atticd = {
      description = "Attic Binary Cache Server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        User = "attic";
        Group = "attic";
        Restart = "on-failure";
        RestartSec = 5;

        # Security settings
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];

        # Use a wrapper script to read the JWT secret
        ExecStart = pkgs.writeShellScript "atticd-start" ''
          export ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64="$(cat ${cfg.jwtSecretFile})"
          exec ${pkgs.attic-server}/bin/atticd -f /etc/atticd/config.toml
        '';
      };

      # Run database migrations on first start or upgrades
      preStart = ''
        ${pkgs.attic-server}/bin/atticd -f /etc/atticd/config.toml --mode db-migrations
      '';
    };

    # Reverse proxy configuration
    services.caddy = lib.mkIf cfg.reverseProxy.enable {
      enable = true;
      virtualHosts."${cfg.reverseProxy.virtualHost}" = {
        extraConfig = ''
          reverse_proxy ${cfg.listenAddress}

          # Security headers
          header {
            Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
            X-Content-Type-Options "nosniff"
            X-Frame-Options "DENY"
            X-XSS-Protection "1; mode=block"
            Referrer-Policy "strict-origin-when-cross-origin"
          }
        '';
      };
    };

    # Firewall configuration for direct access (if not using reverse proxy)
    networking.firewall = lib.mkIf (!cfg.reverseProxy.enable) {
      allowedTCPPorts = [ (lib.toInt (lib.last (lib.splitString ":" cfg.listenAddress))) ];
    };

    # Package requirements
    environment.systemPackages = with pkgs; [
      attic-client
      attic-server
    ];
  };
}
