# mx-edge: the inbound mail edge relay on Vultr (k8s-gitops ADR 0014).
# Public MX for holthome.net. Stalwart, MTA only, accepts mail for the
# mail domains, filters it, and relays it over the tailnet to the cluster's
# Stalwart listener smtp-edge. Nothing else listens publicly but SSH, which
# the Vultr firewall group limits to the home address.
{ pkgs
, lib
, hostname
, inputs
, ...
}:
{
  imports = [
    ./hardware-configuration.nix
    (import ./disko-config.nix { disks = [ "/dev/vda" ]; })
    ./secrets.nix
    ./stalwart.nix
    ./tailscale.nix
  ];

  config = {
    system.stateVersion = "26.05";

    nix = {
      # The newest Nix, not the release default.
      package = pkgs.nixVersions.latest;
      # modules/common/nix.nix points these at the fleet's nixpkgs; this
      # host is built from nixpkgs-mx-edge (flake.nix).
      registry.nixpkgs.flake = lib.mkForce inputs.nixpkgs-mx-edge;
      nixPath = lib.mkForce [ "nixpkgs=${inputs.nixpkgs-mx-edge.outPath}" ];
    };

    networking = {
      hostName = hostname;
      useDHCP = true;
      # IPv6 by router advertisements, which Vultr sends once IPv6 is on.
      enableIPv6 = true;
      firewall = {
        enable = true;
        # SMTP from the internet. SSH is opened by modules.services.openssh.
        allowedTCPPorts = [ 25 ];
      };
    };

    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    # 1 GiB of RAM. Swap keeps an upgrade's evaluation and a burst of mail
    # from waking the OOM killer.
    swapDevices = [{ device = "/var/lib/swapfile"; size = 2048; }];
    zramSwap.enable = false;

    users.users.ryan = {
      uid = 1000;
      group = "ryan";
      home = "/home/ryan";
      shell = pkgs.fish;
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = lib.strings.splitString "\n" (builtins.readFile ../../home/ryan/config/ssh/ssh.pub);
    };
    users.groups.ryan.gid = 1000;

    modules = {
      services.openssh.enable = true;
      autoUpgrade = {
        enable = true;
        allowReboot = true;
        rebootWindow = {
          lower = "04:00";
          upper = "05:00";
        };
        # Evaluation of the flake is the heavy part on 1 GiB; swap absorbs it.
        memoryMax = "1536M";
      };
    };
  };
}
