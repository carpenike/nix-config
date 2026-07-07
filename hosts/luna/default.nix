{ pkgs
, lib
, config
, hostname
, ...
}:
let
  ifGroupsExist = groups: builtins.filter (group: builtins.hasAttr group config.users.groups) groups;
in
{
  imports = [
    ./hardware-configuration.nix
    (import ./disko-config.nix {
      disks = [ "/dev/sda" ];
      inherit lib; # Pass lib here
    })
    ./secrets.nix
    ./systemPackages.nix

    # Unified backup system (modules.services.backup). Luna doesn't import the
    # "backup" service category in flake.nix, so pull in the module directly.
    ../../modules/nixos/services/backup
  ];

  config = {
    # Primary IP for DNS record generation
    my.hostIp = "10.20.0.15";

    networking = {
      hostName = hostname;
      hostId = "506a4dd5";
      useDHCP = true;
      domain = "holthome.net"; # Base domain for reverse proxy

      # Host firewall. Most listening services open their own ports via their
      # modules; only ports without a module-managed rule are listed here.
      #
      # Module-opened ports (for reference):
      #   22/tcp            openssh module
      #   80,443/tcp        caddy module (reverse proxy for all web UIs)
      #   8080,8443/tcp     unifi module (device inform, controller UI)
      #   3478/udp          unifi module (STUN)
      #   8043,8843,29814/tcp + 29810/udp  omada module (UI, portal, discovery)
      #   8000/tcp          onepassword-connect module (API)
      #   9100/tcp          node-exporter module (Prometheus scrape from forge)
      # AdGuardHome web UI (3000) binds 127.0.0.1 and is only reachable via Caddy.
      firewall = {
        enable = true;
        allowedTCPPorts = [
          53 # AdGuardHome DNS (TCP fallback / large responses)
        ];
        allowedUDPPorts = [
          53 # AdGuardHome DNS
          123 # chrony NTP (configured as a LAN time server: allow all)
        ];
      };
    };

    # Boot loader configuration
    boot.loader = {
      systemd-boot = {
        enable = true;
        # Cap boot entries on the ~500MB ESP; auto-upgrade generates frequent
        # generations and an unbounded ESP eventually fails upgrades.
        configurationLimit = 10;
      };
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
      # Automatic system upgrades from GitHub (same pattern as forge).
      # Scheduled AFTER forge's 04:00-05:00 window: forge's upgrade pulls the
      # flake from GitHub and needs working DNS, so luna (the primary resolver)
      # must not be rebooting at that time.
      autoUpgrade = {
        enable = true;
        schedule = "05:15";
        allowReboot = true;
        rebootWindow = {
          lower = "05:15";
          upper = "06:00";
        };
      };

      services = {
        # Enable Caddy reverse proxy
        caddy = {
          enable = true;
          domain = "holthome.net";
        };

        # BIND disabled - was used for Kubernetes DNS support
        # Now using Mikrotik DNS for holthome.net:
        # - DHCP-to-DNS auto-registration for clients
        # - Static entries for infrastructure (forge, nas-1, etc.)
        # AdGuard forwards *.holthome.net queries to Mikrotik (10.10.0.1)
        # bind = {
        #   enable = true;
        #   shared.enable = true;
        # };

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
          # Backup the root-refreshed dump (state files are 0600 adguardhome-owned,
          # unreadable by the restic-backup user; see luna-backup-dumps below).
          # Overrides the module default, which assumes forge's tank ZFS layout.
          backup = {
            enable = true;
            repository = "nas-primary";
            paths = [ "/var/lib/backup-dumps/adguardhome" ];
            tags = [ "adguardhome" "dns" "config" "luna" ];
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

        # Commented out - no longer using Kubernetes
        # haproxy = {
        #   enable = true;
        #   shared = {
        #     enable = true; # Use shared configuration
        #     useDnsDependency = true;
        #   };
        # };

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
            hostName = "vault.${config.networking.domain}";
            # No external auth: Connect uses native token-based auth (OP_CONNECT_TOKEN);
            # the shared submodule's `auth` defaults to null, so leaving it unset
            # means Caddy will not enforce its own auth layer in front.
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
          # Backup the mongodump + config refreshed by luna-backup-dumps
          # (migrated from the legacy backup-services module).
          backup = {
            enable = true;
            repository = "nas-primary";
            paths = [ "/var/lib/backup-dumps/unifi" ];
            tags = [ "unifi" "controller" "database" "luna" ];
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
            memory = "4g"; # Recommended by Perplexity for Omada 5.14 with embedded MongoDB
            memoryReservation = "2g"; # Reserve half for stable operation
            cpus = "2.0"; # 2 cores recommended for Omada + MongoDB
          };
          # Backup the controller export refreshed by luna-backup-dumps
          # (migrated from the legacy backup-services module).
          backup = {
            enable = true;
            repository = "nas-primary";
            paths = [ "/var/lib/backup-dumps/omada" ];
            tags = [ "omada" "controller" "database" "luna" ];
          };
        };

        # Attic moved to nas-1 (2025-12-19)
        # attic = {
        #   enable = true;
        #   listenAddress = "127.0.0.1:8081";
        #   jwtSecretFile = config.sops.secrets."attic/jwt-secret".path;
        #   reverseProxy = {
        #     enable = true;
        #     hostName = "attic.holthome.net";
        #     backend = {
        #       scheme = "http";
        #       host = "127.0.0.1";
        #       port = 8081;
        #     };
        #   };
        #   autoPush = {
        #     enable = true;
        #     cacheName = "homelab";
        #   };
        # };

        # attic-admin = {
        #   enable = true;
        # };

        # Attic push client - DISABLED (not functional, causes multi-hour delays)
        # attic-push = {
        #   enable = true;
        #   cacheName = "homelab";
        #   tokenFile = config.sops.secrets."attic/push-token".path;
        # };
      };

      # Explicitly enable ZFS filesystem module
      filesystems.zfs = {
        enable = true;
        mountPoolsAtBoot = [ "rpool" ];
      };

      system.impermanence = {
        enable = true;

        # =====================================================================
        # Service data persistence
        # =====================================================================
        # Luna uses a single-disk impermanent root. Services that store data
        # in /var/lib/* need their directories listed here to survive reboots.
        #
        # Simple path:
        #   "/var/lib/myservice"
        #
        # With ownership (for services that run as non-root):
        #   { directory = "/var/lib/myservice"; user = "myservice"; group = "myservice"; mode = "0750"; }
        # =====================================================================
        directories = [
          # Network controllers
          "/var/lib/omada"
          "/var/lib/unifi"

          # AdGuardHome state (AdGuardHome.yaml, query log, stats).
          # mutableSettings = true means UI-made config lives ONLY in this
          # directory - without persistence it is wiped on every reboot.
          {
            directory = "/var/lib/AdGuardHome";
            user = "adguardhome";
            group = "adguardhome";
            mode = "0700";
          }

          # Reverse proxy (ACME certificates)
          {
            directory = "/var/lib/caddy";
            user = "caddy";
            group = "caddy";
            mode = "0750";
          }
        ];
      };

      # Unified backup system (restic → nas-1 over NFS).
      # Jobs are auto-discovered from the per-service `backup` submodules above
      # (adguardhome, unifi, omada); the luna-backup-dumps service below stages
      # root-only data where the restic-backup user can read it.
      # Migrated from the legacy modules.services.backup-services module (now
      # deleted); the UniFi mongodump no longer needs credentials because the
      # jacobalberty container runs its embedded mongod without auth.
      services.backup = {
        enable = true;
        restic.enable = true;

        repositories = {
          nas-primary = {
            url = "/mnt/nas-backup";
            passwordFile = config.sops.secrets."restic/password".path;
            primary = true;
            type = "local";
            repositoryName = "NFS";
            repositoryLocation = "nas-1";
          };
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

    # =========================================================================
    # Backup plumbing (restic repository + application dumps)
    # =========================================================================

    # Restic repository password.
    # Declared here (rather than secrets.nix) alongside the backup wiring.
    # MANUAL STEP: add `restic/password` to hosts/luna/secrets.sops.yaml
    # before deploying (e.g. reuse the same repository password as forge).
    sops.secrets."restic/password" = {
      mode = "0400";
      owner = "restic-backup";
      group = "restic-backup";
    };

    # Restic backup storage on nas-1 (same automount pattern as forge).
    # The export + directory are declared in hosts/nas-1/infrastructure/nfs.nix -
    # deploy nas-1 before (or with) this change so the mount resolves.
    fileSystems."/mnt/nas-backup" = {
      device = "nas-1.holthome.net:/mnt/backup/luna/restic";
      fsType = "nfs";
      options = [
        "nfsvers=4.2"
        "rw"
        "noatime"
        "noauto" # don't mount at boot; automount will trigger on access
        "_netdev" # mark as network device
        "x-systemd.automount" # create/enable automount unit
        "x-systemd.idle-timeout=600" # unmount after 10 minutes idle
        "x-systemd.mount-timeout=30s" # fail fast if NAS is down
        "x-systemd.force-unmount=true" # force unmount on shutdown to avoid hangs
        "x-systemd.after=network-online.target"
        "x-systemd.requires=network-online.target"
      ];
    };

    # Stage application data where the (unprivileged) restic-backup user can
    # read it. Runs as root: AdGuardHome state is 0600 adguardhome-owned, and
    # the UniFi/Omada dumps need podman exec into the controller containers.
    # Pulled in via Wants/After by each discovered restic job below, so the
    # dumps are refreshed right before every backup run.
    systemd.services.luna-backup-dumps = {
      description = "Stage AdGuardHome/UniFi/Omada dumps for restic backups";
      path = [ pkgs.podman pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -euo pipefail
        dumps=/var/lib/backup-dumps
        install -d -m 0750 -o root -g restic-backup "$dumps"

        stage() {
          # stage <name> <src-dir>: atomically replace $dumps/<name> with <src-dir>
          rm -rf "$dumps/$1.new"
          mv "$2" "$dumps/$1.new"
          rm -rf "$dumps/$1"
          mv "$dumps/$1.new" "$dumps/$1"
        }

        # --- AdGuardHome: config + state (0600 adguardhome-owned) ---
        work=$(mktemp -d)
        cp -a /var/lib/AdGuardHome "$work/adguardhome"
        stage adguardhome "$work/adguardhome"

        # --- UniFi: mongodump of the embedded MongoDB (no auth in the
        #     jacobalberty image) + controller config/keystore ---
        work=$(mktemp -d)
        mkdir -p "$work/unifi"
        podman exec unifi mongodump --host localhost:27017 --gzip --archive \
          > "$work/unifi/mongodump.archive.gz"
        cp -a /var/lib/unifi/data "$work/unifi/data"
        stage unifi "$work/unifi"

        # --- Omada: mongoexport of key collections + controller backup dir ---
        work=$(mktemp -d)
        mkdir -p "$work/omada"
        podman exec omada mongoexport --db omada --collection sites \
          --out /opt/tplink/EAPController/data/backup/sites.json || true
        podman exec omada mongoexport --db omada --collection devices \
          --out /opt/tplink/EAPController/data/backup/devices.json || true
        podman cp omada:/opt/tplink/EAPController/data/backup "$work/omada/" || true
        stage omada "$work/omada"

        # Make everything readable by the restic-backup user
        chown -R root:restic-backup "$dumps"
        chmod -R g+rX "$dumps"
      '';
    };

    # Refresh the dumps before each discovered backup job runs
    systemd.services."restic-backup-service-adguardhome" = {
      wants = [ "luna-backup-dumps.service" ];
      after = [ "luna-backup-dumps.service" ];
    };
    systemd.services."restic-backup-service-unifi" = {
      wants = [ "luna-backup-dumps.service" ];
      after = [ "luna-backup-dumps.service" ];
    };
    systemd.services."restic-backup-service-omada" = {
      wants = [ "luna-backup-dumps.service" ];
      after = [ "luna-backup-dumps.service" ];
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
