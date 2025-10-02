{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.modules.services.adguardhome;
  adguardUser = "adguardhome";
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

    # Reverse proxy integration options
    reverseProxy = {
      enable = lib.mkEnableOption "Caddy reverse proxy integration for AdGuardHome";
      subdomain = lib.mkOption {
        type = lib.types.str;
        default = "adguard";
        description = "Subdomain to use for the reverse proxy";
      };
      requireAuth = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to require authentication (AdGuardHome has its own login)";
      };
      auth = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            user = lib.mkOption {
              type = lib.types.str;
              default = "admin";
              description = "Username for basic authentication";
            };
            passwordHashEnvVar = lib.mkOption {
              type = lib.types.str;
              description = "Name of environment variable containing bcrypt password hash";
            };
          };
        });
        default = null;
        description = "Authentication configuration for AdGuardHome web interface";
      };
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
    modules.services.caddy.virtualHosts.${cfg.reverseProxy.subdomain} = lib.mkIf cfg.reverseProxy.enable {
      enable = true;
      hostName = "${cfg.reverseProxy.subdomain}.${config.modules.services.caddy.domain or config.networking.domain or "holthome.net"}";
      proxyTo = "localhost:${toString config.services.adguardhome.port}"; # Use dynamic port reference
      httpsBackend = false; # AdGuardHome uses HTTP locally
      auth = lib.mkIf (cfg.reverseProxy.requireAuth && cfg.reverseProxy.auth != null) cfg.reverseProxy.auth;
      extraConfig = ''
        # AdGuardHome web interface headers
        header / {
          X-Frame-Options "SAMEORIGIN"
          X-Content-Type-Options "nosniff"
          X-XSS-Protection "1; mode=block"
          Referrer-Policy "strict-origin-when-cross-origin"
        }
      '';
    };
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
