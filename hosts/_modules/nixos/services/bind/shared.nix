{ lib, config, ... }:
let
  cfg = config.modules.services.bind.shared;
in
{
  options.modules.services.bind.shared = {
    enable = lib.mkEnableOption "the shared holthome.net BIND configuration";

    # Allow host-specific overrides or additions
    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra configuration lines to append for this specific host.";
    };

    extraZones = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Additional zones specific to this host as zone-name = zone-config pairs.";
    };

    # Network customization options
    networks = {
      trusted = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "10.10.0.0/16"   # LAN
          "10.20.0.0/16"   # Servers
          "10.30.0.0/16"   # WIRELESS
          "10.40.0.0/16"   # IoT
        ];
        description = "List of trusted network CIDR blocks.";
      };

      blacklisted = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "List of blacklisted network CIDR blocks.";
      };
    };

    # Port configuration
    port = lib.mkOption {
      type = lib.types.int;
      default = 5391;
      description = "Port for BIND to listen on.";
    };

    # Logging customization
    logging = {
      severity = lib.mkOption {
        type = lib.types.enum [ "critical" "error" "warning" "notice" "info" "debug" ];
        default = "info";
        description = "Logging severity level.";
      };
    };
  };

  # When enabled, apply the shared configuration using proper NixOS options
  config = lib.mkIf cfg.enable {
    modules.services.bind = {
      enable = true;
      config = ''
        include "${config.sops.secrets."networking/bind/rndc-key".path}";
        include "${config.sops.secrets."networking/bind/externaldns-key".path}";
        include "${config.sops.secrets."networking/bind/ddnsupdate-key".path}";
        controls {
          inet 127.0.0.1 allow {localhost;} keys {"rndc-key";};
        };

        # Only define known networks as trusted
        acl trusted {
          ${lib.concatMapStringsSep "\n  " (net: "${net};") cfg.networks.trusted}
        };
        acl badnetworks {
          ${lib.concatMapStringsSep "\n  " (net: "${net};") cfg.networks.blacklisted}
        };

        options {
          listen-on port ${toString cfg.port} { any; };
          directory "${config.services.bind.directory}";
          pid-file "${config.services.bind.directory}/named.pid";

          allow-recursion { trusted; };
          allow-transfer { none; };
          allow-update { none; };
          blackhole { badnetworks; };
          dnssec-validation auto;
        };

        logging {
          channel stdout {
            stderr;
            severity ${cfg.logging.severity};
            print-category yes;
            print-severity yes;
            print-time yes;
          };
          category security { stdout; };
          category dnssec   { stdout; };
          category default  { stdout; };
        };

        zone "holthome.net." {
          type master;
          file "${config.sops.secrets."networking/bind/zones/holthome.net".path}";
          journal "${config.services.bind.directory}/db.holthome.net.jnl";
          allow-transfer {
            key "externaldns";
          };
          update-policy {
            grant externaldns zonesub ANY;
            grant ddnsupdate zonesub ANY;
            grant * self * A;
          };
        };

        zone "10.in-addr.arpa." {
          type master;
          file "${config.sops.secrets."networking/bind/zones/10.in-addr.arpa".path}";
          journal "${config.services.bind.directory}/db.10.in-addr.arpa.jnl";
          update-policy {
            grant ddnsupdate zonesub ANY;
            grant * self * A;
          };
        };

        ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: zoneConfig: ''
          zone "${name}" {
            ${zoneConfig}
          };
        '') cfg.extraZones)}

        ${cfg.extraConfig}
      '';
    };
  };
}
