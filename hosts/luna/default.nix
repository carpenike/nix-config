{
  pkgs,
  lib,
  config,
  hostname,
  ...
}:
let
  ifGroupsExist = groups: builtins.filter (group: builtins.hasAttr group config.users.groups) groups;
in
{
  imports = [
    ./hardware-configuration.nix
    (import ./disko-config.nix {
      disks = [ "/dev/sda" ];
      inherit lib;  # Pass lib here
    })
    ./secrets.nix
    ./systemPackages.nix
  ];

  config = {
    # Primary IP for DNS record generation
    my.hostIp = "10.20.0.15";

    networking = {
      hostName = hostname;
      hostId = "506a4dd5";
      useDHCP = true;
      firewall.enable = false;
      domain = "holthome.net"; # Base domain for reverse proxy
    };

    # Boot loader configuration
    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    users.users.ryan = {
      uid = 1000;
      name = "ryan";
      home = "/home/ryan";
      group = "ryan";
      shell = pkgs.fish;
      openssh.authorizedKeys.keys = lib.strings.splitString "\n" (builtins.readFile ../../home/ryan/config/ssh/ssh.pub);
      isNormalUser = true;
      extraGroups =
        [
          "wheel"
          "users"
        ]
        ++ ifGroupsExist [
          "network"
        ];
    };
    users.groups.ryan = {
      gid = 1000;
    };

    system.activationScripts.postActivation.text = ''
      # Must match what is in /etc/shells
      chsh -s /run/current-system/sw/bin/fish ryan
    '';

    modules = {
      services = {
        # Enable Caddy reverse proxy
        caddy = {
          enable = true;
          domain = "holthome.net";
        };

        bind = {
          enable = true;
          shared.enable = true; # Use shared holthome.net configuration
        };

        # Note: Disabled blocky in favor of AdGuardHome
        # blocky = {
        #   enable = true;
        #   package = pkgs.unstable.blocky;
        #   config = import ./config/blocky.nix;
        # };

        adguardhome = {
          enable = true;
          mutableSettings = true; # Allow web UI changes to persist
          settings = import ./config/adguard.nix { inherit config lib; };
          reverseProxy = {
            enable = true;
            hostName = "adguard.${config.networking.domain}";
            backend = {
              scheme = "http";
              host = "127.0.0.1";
              port = 3000;
            };
          };
        };

        chrony = {
          enable = true;
          servers = [
            "0.us.pool.ntp.org"
            "1.us.pool.ntp.org"
            "2.us.pool.ntp.org"
            "3.us.pool.ntp.org"
          ];
        };

        # Disabled dnsdist - using AdGuardHome directly on port 53
        # dnsdist = {
        #   enable = false;
        # };

        haproxy = {
          enable = true;
          shared = {
            enable = true; # Use shared configuration
            useDnsDependency = true;
          };
        };

        node-exporter = {
          enable = true;
          reverseProxy = {
            enable = true;
            hostName = "node-exporter.${config.networking.domain}";
            backend = {
              scheme = "http";
              host = "127.0.0.1";
              port = 9100;
            };
            auth = {
              user = "metrics";
              passwordHashEnvVar = "CADDY_METRICS_HASH";
            };
          };
        };

        glances = {
          enable = true;
          reverseProxy = {
            enable = true;
            hostName = "${config.networking.hostName}.${config.networking.domain}";
            backend = {
              scheme = "http";
              host = "127.0.0.1";
              port = 61208;
            };
            caddySecurity = {
              enable = true;
              portal = "pocketid";
              policy = "admins";
              claimRoles = [
                {
                  claim = "groups";
                  value = "admins";
                  role = "admins";
                }
              ];
            };
          };
        };

        onepassword-connect = {
          enable = true;
          credentialsFile = config.sops.secrets.onepassword-credentials.path;
          reverseProxy = {
            enable = true;
            # NOTE: Uses native token-based auth (OP_CONNECT_TOKEN)
            # No additional auth needed at reverse proxy level
            requireAuth = false;
          };
        };

        openssh.enable = true;

        unifi = {
          enable = true;
          reverseProxy = {
            enable = true;
            hostName = "unifi.${config.networking.domain}";
            backend = {
              scheme = "https";
              host = "127.0.0.1";
              port = 8443;
            };
          };
        };

        omada = {
          enable = true;
          reverseProxy = {
            enable = true;
            hostName = "omada.${config.networking.domain}";
            backend = {
              scheme = "https";
              host = "127.0.0.1";
              port = 8043;
            };
          };
          resources = {
            memory = "4g";            # Recommended by Perplexity for Omada 5.14 with embedded MongoDB
            memoryReservation = "2g"; # Reserve half for stable operation
            cpus = "2.0";             # 2 cores recommended for Omada + MongoDB
          };
        };

        attic = {
          enable = true;
          listenAddress = "127.0.0.1:8081";  # Use different port to avoid UniFi conflict
          jwtSecretFile = config.sops.secrets."attic/jwt-secret".path;
          reverseProxy = {
            enable = true;
            hostName = "attic.holthome.net";
            backend = {
              scheme = "http";
              host = "127.0.0.1";
              port = 8081;
            };
          };
          autoPush = {
            enable = true;
            cacheName = "homelab";
          };
        };

        attic-admin = {
          enable = true;
        };
      };

      # Explicitly enable ZFS filesystem module
      filesystems.zfs = {
        enable = true;
        mountPoolsAtBoot = [ "rpool" ];
      };

      system.impermanence.enable = true;

      # Backup system disabled for now - needs full configuration
      # backup = {
      #   enable = false;
      # };

      # Service-specific backup configurations (disabled with main backup module)
      services.backup-services = {
        enable = false;

        unifi = {
          enable = config.modules.services.unifi.enable or false;
          mongoCredentialsFile = "/run/secrets/rendered/unifi-mongo-credentials";
        };

        omada = {
          enable = config.modules.services.omada.enable or false;
          containerName = "omada";
        };

        onepassword-connect = {
          enable = config.modules.services.onepassword-connect.enable or false;
          credentialsFile = config.sops.secrets.onepassword-credentials.path;
        };

        attic = {
          enable = config.modules.services.attic.enable or false;
          useZfsSend = false;  # Temporarily disable ZFS send to avoid conflicts
          nasDestination = "backup@nas.holthome.net";
        };

        system = {
          enable = true;
          paths = [
            "/etc/nixos"
            "/home/ryan/.config"
            "/var/log"
            "/persist"
          ];
        };
      };

      users = {
        groups = {
          admins = {
            gid = 991;
            members = [
              "ryan"
            ];
          };
        };
      };
    };

    # Configure Caddy to load environment file with SOPS secrets
    systemd.services.caddy.serviceConfig.EnvironmentFile = "/run/secrets/rendered/caddy-env";

    # Create environment file from SOPS secrets
    sops.templates."caddy-env" = {
      content = ''
        CADDY_METRICS_HASH=${config.sops.placeholder."reverse-proxy/metrics-auth"}
        CADDY_VAULT_HASH=${config.sops.placeholder."reverse-proxy/vault-auth"}
        CADDY_GLANCES_HASH=${config.sops.placeholder."reverse-proxy/glances-auth"}
        CLOUDFLARE_API_TOKEN=${lib.strings.removeSuffix "\n" config.sops.placeholder."networking/cloudflare/ddns/apiToken"}
      '';
      owner = config.services.caddy.user;
      group = config.services.caddy.group;
    };
  };
}
