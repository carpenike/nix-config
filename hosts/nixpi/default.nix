{
  pkgs,
  lib,
  config,
  hostname,
  inputs,
  ...
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

    # Import coachiq module for RV monitoring
    inputs.coachiq.nixosModules.coachiq
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
        "dialout"  # For serial/CAN access
        "gpio"     # For GPIO access
        "i2c"      # For I2C devices
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
        node-exporter.enable = true;  # System monitoring

        glances = {
          enable = true;
          openFirewall = true;
        };

        cloudflared.enable = true;

        caddy = {
          enable = true;
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
        };

        "20-wireless" = {
          matchConfig.Name = "wlan0";
          networkConfig.DHCP = "ipv4";
        };
      };
    };

    # WiFi secrets management
    systemd.tmpfiles.rules = [
      "C /var/lib/iwd/iot.psk 0600 root root - ${config.sops.secrets."wifi/iot_password".path}"
      "C /var/lib/iwd/rvproblems-2ghz.psk 0600 root root - ${config.sops.secrets."wifi/rvproblems_password".path}"
    ];


    # Configure coachiq for RV monitoring
    coachiq = {
      enable = true;
      settings = {
        server = {
          host = "0.0.0.0";
          port = 8000;
        };

        canbus = {
          channels = [ "can0" "can1" ];
          bustype = "socketcan";
          bitrate = 500000;
          interfaceMappings = {
            house = "can1";    # House systems -> can1
            chassis = "can0";  # Chassis systems -> can0
          };
        };

        security = {
          tlsTerminationIsExternal = true;
        };

        controllerSourceAddr = "0xF9";
        rvcCoachModel = "2021_Entegra_Aspire_44R";
        githubUpdateRepo = "carpenike/coachiq";
      };
    };

    # Additional system configuration
    hardware.enableRedistributableFirmware = true;

    # Nix settings for Raspberry Pi
    nix.settings = {
      download-buffer-size = 33554432; # 32 MiB
    };
  };
}
