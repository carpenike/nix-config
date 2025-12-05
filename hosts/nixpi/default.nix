{ pkgs
, lib
, config
, hostname
, inputs
, ...
}:
let
  ifGroupsExist = groups: builtins.filter (group: builtins.hasAttr group config.users.groups) groups;
in
{
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
    ./systemPackages.nix
    ./storage.nix

    # Use nixos-hardware for Raspberry Pi 4 support (same as original repo)
    inputs.hardware.nixosModules.raspberry-pi-4
  ];

  config = {
    networking = {
      hostName = hostname;

      # Use systemd-networkd
      useNetworkd = true;
      useDHCP = false;

      # Enable wireless with iwd
      wireless.iwd = {
        enable = true;
        settings = {
          General = {
            EnableNetworkConfiguration = true;
          };
          DriverQuirks = {
            DefaultInterface = "wlan0";
            DisableHt = false;
            DisableVht = false;
            DisableHe = true;
          };
        };
      };
    };

    # Boot configuration
    boot = {
      loader = {
        systemd-boot.enable = false;
        efi.canTouchEfiVariables = false;
      };

      kernel.sysctl = {
        "net.core.rmem_max" = 7500000;
        "net.core.wmem_max" = 7500000;
        "net.ipv4.ip_forward" = 1;

        # Allow replies to go out different interface than requests came in
        # This fixes accessibility when both ethernet and WiFi are connected
        "net.ipv4.conf.all.rp_filter" = 2; # Loose mode
        "net.ipv4.conf.default.rp_filter" = 2;
      };
    };

    # Locale is handled by common module

    # Users
    users.users.ryan = {
      uid = 1000;
      name = "ryan";
      home = "/home/ryan";
      group = "ryan";
      shell = pkgs.fish;
      openssh.authorizedKeys.keys = lib.strings.splitString "\n" (builtins.readFile ../../home/ryan/config/ssh/ssh.pub);
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "users"
        "dialout" # For serial/CAN access
        "gpio" # For GPIO access
        "i2c" # For I2C devices
      ] ++ ifGroupsExist [
        "network"
      ];
    };

    users.groups.ryan = {
      gid = 1000;
    };

    # System activation scripts
    system.activationScripts.postActivation.text = ''
      # Set shell
      chsh -s /run/current-system/sw/bin/fish ryan
    '';

    # Enable hardware modules
    modules = {
      # Hardware
      hardware = {
        # Don't enable our raspberry-pi module as we're using raspberry-pi-nix directly
        # raspberryPi.enable = true;
        pican2Duo.enable = true;
        hwclock.enable = true;
        watchdog.enable = true;
      };

      # Services
      services = {
        openssh.enable = true;
        node-exporter.enable = true; # System monitoring

        glances = {
          enable = true;
          # Note: Reverse proxy disabled - nixpi doesn't have domain configured
          # Glances binds to localhost only for security
        };

        # cloudflared.enable = true;  # TODO: Add cloudflare secrets to secrets.sops.yaml

        caddy = {
          enable = true;
          # Now includes reverse proxy functionality via reverseProxy option
        };

        chrony = {
          enable = true;
          servers = [ "time.cloudflare.com" ];
        };
      };
    };

    # WiFi configuration via systemd-networkd
    systemd.network = {
      enable = true;
      wait-online.enable = false;

      networks = {
        "10-wired" = {
          matchConfig.Name = "end0";
          networkConfig.DHCP = "ipv4";
          dhcpV4Config.RouteMetric = 100; # Lower metric = higher priority
        };

        "20-wireless" = {
          matchConfig.Name = "wlan0";
          networkConfig.DHCP = "ipv4";
          dhcpV4Config.RouteMetric = 200; # Higher metric = lower priority
        };
      };
    };

    # WiFi secrets management
    systemd.tmpfiles.rules = [
      "C /var/lib/iwd/iot.psk 0600 root root - ${config.sops.secrets."wifi/iot_password".path}"
      "C /var/lib/iwd/rvproblems-2ghz.psk 0600 root root - ${config.sops.secrets."wifi/rvproblems_password".path}"
    ];

    # Additional system configuration
    hardware.enableRedistributableFirmware = true;

    # Nix settings for Raspberry Pi
    nix.settings = {
      download-buffer-size = 33554432; # 32 MiB
    };
  };
}
