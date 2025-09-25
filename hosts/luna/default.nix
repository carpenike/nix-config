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
    networking = {
      hostName = hostname;
      hostId = "506a4dd5";
      useDHCP = true;
      firewall.enable = false;
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
        bind = {
          enable = true;
          shared.enable = true; # Use shared holthome.net configuration
        };

        blocky = {
          enable = true;
          package = pkgs.unstable.blocky;
          config = import ./config/blocky.nix;
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

        dnsdist = {
          enable = true;
          shared = {
            enable = true;
            # Luna has RV DNS server
            additionalServers = [{
              address = "192.168.88.1:53";
              pool = "rv";
              options = ''
                healthCheckMode = "lazy",
                checkInterval = 1800,
                maxCheckFailures = 3,
                lazyHealthCheckFailedInterval = 30,
                rise = 2,
                lazyHealthCheckThreshold = 30,
                lazyHealthCheckSampleSize = 100,
                lazyHealthCheckMinSampleCount = 10,
                lazyHealthCheckMode = 'TimeoutOnly',
                useClientSubnet = true
              '';
            }];
            # Luna-specific domain routing
            domainRouting = {
              "holtel.io" = "rv";
            };
            # Network routing configuration
            networkRouting = [
              # Guest and Video VLANs - isolated
              { subnet = "10.35.0.0/16"; pool = "cloudflare_general"; description = "guest vlan"; dropAfter = true; }
              { subnet = "10.50.0.0/16"; pool = "cloudflare_general"; description = "video vlan"; dropAfter = true; }
              # Docker and LAN networks
              { subnet = "10.88.0.0/24"; pool = "adguard"; description = "local docker network"; }
              { subnet = "10.10.0.0/16"; pool = "adguard"; description = "lan"; }
              # Management and server VLANs
              { subnet = "10.8.0.0/24"; pool = "cloudflare_general"; description = "wireguard"; }
              { subnet = "10.9.18.0/24"; pool = "cloudflare_general"; description = "mgmt"; }
              { subnet = "10.20.0.0/16"; pool = "cloudflare_general"; description = "servers vlan"; }
              # Trusted and IoT VLANs
              { subnet = "10.30.0.0/16"; pool = "adguard"; description = "trusted vlan"; }
              { subnet = "10.40.0.0/16"; pool = "cloudflare_general"; description = "iot vlan"; }
              # Additional trusted networks
              { subnet = "10.11.0.0/16"; pool = "adguard"; description = "wg_trusted vlan"; }
              { subnet = "10.6.0.0/16"; pool = "adguard"; description = "services vlan"; }
              { subnet = "192.168.50.0/24"; pool = "adguard"; description = "RV"; }
            ];
          };
        };

        haproxy = {
          enable = true;
          shared = {
            enable = true; # Use shared configuration
            useDnsDependency = true;
          };
        };

        node-exporter.enable = true;

        onepassword-connect = {
          enable = true;
          credentialsFile = config.sops.secrets.onepassword-credentials.path;
        };

        openssh.enable = true;

        unifi.enable = true;

        omada.enable = true;
      };

      # Explicitly enable ZFS filesystem module
      filesystems.zfs = {
        enable = true;
        mountPoolsAtBoot = [ "rpool" ];
      };

      system.impermanence.enable = true;

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
  };
}
