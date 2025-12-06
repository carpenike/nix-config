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
    (import ./disko-config.nix { disks = [ "/dev/sda" ]; })
    ./secrets.nix
  ];

  config = {
    # Primary IP for DNS record generation
    my.hostIp = "10.20.0.20";

    networking = {
      hostName = hostname;
      hostId = "506a4dd5";
      useDHCP = true;
      firewall.enable = true;
      domain = "holthome.net";
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
        chrony = {
          enable = true;
          servers = [
            "0.us.pool.ntp.org"
            "1.us.pool.ntp.org"
            "2.us.pool.ntp.org"
            "3.us.pool.ntp.org"
          ];
        };

        # Test the new standardized metrics pattern
        node-exporter = {
          enable = true;
          # metrics configuration is auto-enabled by default
          # This should automatically register with Prometheus
        };

        # Enable observability stack to test auto-discovery
        observability = {
          enable = true;
          prometheus.enable = true;
          autoDiscovery.enable = true;
          # Disable other components for this test
          loki.enable = false;
          promtail.enable = false;
          grafana.enable = false;
        };

        openssh.enable = true;
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

    # Use the systemd-boot EFI boot loader.
    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
  };
}
