{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.modules.services.adguardhome;
  adguardUser = "adguardhome";
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
in
{
  imports = [ ./shared.nix ]; # Import the shared options module

  options.modules.services.adguardhome = {
    enable = lib.mkEnableOption "adguardhome";
    package = lib.mkPackageOption pkgs "adguardhome" { };
    settings = lib.mkOption {
      default = {};
      type = lib.types.attrs;
    };
    mutableSettings = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to allow settings to be changed via web UI.";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for AdGuardHome web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = null; # AdGuardHome doesn't natively expose Prometheus metrics
      description = "Prometheus metrics collection configuration for AdGuardHome";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "adguardhome.service";
        labels = {
          service = "adguardhome";
          service_type = "dns_filter";
        };
      };
      description = "Log shipping configuration for AdGuardHome logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "dns" "adguardhome" "config" ];
        # CRITICAL: Enable ZFS snapshots for query log and configuration consistency
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/adguardhome";
        excludePatterns = lib.mkDefault [
          "**/cache/**"          # Exclude cache files
          "**/tmp/**"            # Exclude temporary files
        ];
      };
      description = "Backup configuration for AdGuardHome";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "dns-alerts" ];
        };
        customMessages = {
          failure = "AdGuardHome DNS filter failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for AdGuardHome service events";
    };
  };

  config = lib.mkIf cfg.enable {
    services.adguardhome = {
      enable = true;
      host = "127.0.0.1";  # Restrict web UI to localhost only (force traffic through Caddy)
      port = 3000;         # Extract from settings
      inherit (cfg) mutableSettings;
      settings = builtins.removeAttrs cfg.settings [ "bind_host" "bind_port" ];
    };

    # Automatically register with Caddy reverse proxy if enabled
    modules.services.caddy.virtualHosts.adguard = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;

      # Use structured backend configuration from shared types
      backend = {
        scheme = "http";  # AdGuardHome uses HTTP locally
        host = "127.0.0.1";
        port = config.services.adguardhome.port;
      };

      # Authentication configuration from shared types
      auth = cfg.reverseProxy.auth;

      # Authelia SSO configuration from shared types
      authelia = cfg.reverseProxy.authelia;

      # Security configuration with AdGuardHome-specific headers
      security = cfg.reverseProxy.security // {
        customHeaders = cfg.reverseProxy.security.customHeaders // {
          "X-Frame-Options" = "SAMEORIGIN";
          "X-Content-Type-Options" = "nosniff";
          "X-XSS-Protection" = "1; mode=block";
          "Referrer-Policy" = "strict-origin-when-cross-origin";
        };
      };

      extraConfig = cfg.reverseProxy.extraConfig;
    };

    # Register with Authelia if SSO protection is enabled
    modules.services.authelia.accessControl.declarativelyProtectedServices.adguard = lib.mkIf (
      config.modules.services.authelia.enable &&
      cfg.reverseProxy != null &&
      cfg.reverseProxy.enable &&
      cfg.reverseProxy.authelia != null &&
      cfg.reverseProxy.authelia.enable
    ) (
      let
        authCfg = cfg.reverseProxy.authelia;
      in {
        domain = cfg.reverseProxy.hostName;
        policy = authCfg.policy;
        subject = map (g: "group:${g}") authCfg.allowedGroups;
        bypassResources =
          (map (path: "^${lib.escapeRegex path}/.*$") (authCfg.bypassPaths or []))
          ++ (authCfg.bypassResources or []);
      }
    );

    # add user, needed to access the secret
    users.users.${adguardUser} = {
      isSystemUser = true;
      group = adguardUser;
    };
    users.groups.${adguardUser} = { };
    # insert password before service starts
    # password in sops is unencrypted, so we bcrypt it
    # and insert it as per config requirements
    systemd.services.adguardhome = {
      # Override the default NixOS adguardhome preStart with improved logic
      # that separates password injection from config sync
      preStart = lib.mkForce ''
        # Password injection: Always replace ADGUARDPASS placeholder if present
        # This ensures initial deployments and mutableSettings=true hosts get bcrypt hash
        if [ -f "$STATE_DIRECTORY/AdGuardHome.yaml" ] && grep -q "ADGUARDPASS" "$STATE_DIRECTORY/AdGuardHome.yaml"; then
          echo "Injecting bcrypt password hash..."
          PASSWORD=$(cat ${config.sops.secrets."networking/adguardhome/password".path})
          HASH=$(${pkgs.apacheHttpd}/bin/htpasswd -B -C 10 -n -b dummy "$PASSWORD" | cut -d: -f2-)
          ${pkgs.gnused}/bin/sed -i "s,ADGUARDPASS,$HASH," "$STATE_DIRECTORY/AdGuardHome.yaml"
        fi

        ${lib.optionalString (!cfg.mutableSettings) ''
          # Declarative config sync: Only when mutableSettings = false
          # The NixOS module's default preStart has broken logic: [ "" = "1" ] always fails
          # This ensures declarative config is applied on every service start
          # Runtime data (query logs, statistics) are stored separately and not affected

          echo "Syncing declarative AdGuard Home configuration..."
          CONFIG_FILE="${pkgs.writeText "AdGuardHome.yaml" (builtins.toJSON config.services.adguardhome.settings)}"
          cp --force "$CONFIG_FILE" "$STATE_DIRECTORY/AdGuardHome.yaml"
          chmod 600 "$STATE_DIRECTORY/AdGuardHome.yaml"

          # Re-inject password after config sync (placeholder gets restored)
          PASSWORD=$(cat ${config.sops.secrets."networking/adguardhome/password".path})
          HASH=$(${pkgs.apacheHttpd}/bin/htpasswd -B -C 10 -n -b dummy "$PASSWORD" | cut -d: -f2-)
          ${pkgs.gnused}/bin/sed -i "s,ADGUARDPASS,$HASH," "$STATE_DIRECTORY/AdGuardHome.yaml"
        ''}
      '';
      serviceConfig.User = adguardUser;
    };

    # Note: firewall ports now managed by shared.nix when shared config is used
  };

}
