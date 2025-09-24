{ lib, config, ... }:
let
  cfg = config.modules.services.adguardhome.shared;
in
{
  options.modules.services.adguardhome.shared = {
    enable = lib.mkEnableOption "the shared AdGuard Home minimal baseline configuration";

    # Network configuration - absolutely required for infrastructure integration
    webPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port for the AdGuard Home web interface.";
      example = 3000;
    };

    dnsPort = lib.mkOption {
      type = lib.types.port;
      default = 5390;
      description = "Port for DNS service.";
      example = 53;
    };

    # Admin user for initial setup
    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Initial admin username.";
      example = "ryan";
    };

    # Internal DNS forwarding - critical for local network operation
    localDnsServer = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:5391";
      description = "Local DNS server for internal domains.";
      example = "192.168.1.1:53";
    };

    localDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "holthome.net"
        "in-addr.arpa"
        "ip6.arpa"
      ];
      description = "Domains to forward to local DNS server.";
      example = ["example.local" "10.in-addr.arpa"];
    };

    # Minimal extra config hook
    extraMinimalConfig = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Additional minimal configuration. Use very sparingly - prefer web UI.";
      example = lib.literalExpression ''
        {
          theme = "dark";
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    modules.services.adguardhome = {
      enable = true;
      mutableSettings = true; # Always allow web UI management
      settings = lib.mkMerge [
        {
          # Absolute minimum required configuration
          schema_version = 24;

          # Network binding
          bind_host = "0.0.0.0";
          bind_port = cfg.webPort;

          # DNS configuration - minimal baseline
          dns = {
            bind_hosts = ["0.0.0.0"];
            port = cfg.dnsPort;

            # Only configure internal domain routing - everything else via web UI
            upstream_dns =
              (map (domain: "[/${domain}/]${cfg.localDnsServer}") cfg.localDomains)
              ++ [ "https://1.1.1.1/dns-query" ]; # Single fallback upstream

            # Minimal bootstrap DNS for initial connectivity
            bootstrap_dns = [
              "1.1.1.1"
              "8.8.8.8"
            ];
          };

          # Initial admin user - password set via systemd
          users = [{
            name = cfg.adminUser;
            password = "ADGUARDPASS"; # Replaced by systemd preStart
          }];

          # Auto-theme
          theme = "auto";
        }
        cfg.extraMinimalConfig
      ];
    };

    # Firewall configuration
    networking.firewall = {
      allowedTCPPorts = [ cfg.webPort ];
      allowedUDPPorts = [ cfg.dnsPort ];
    };
  };
}
