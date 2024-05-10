{ lib, config, pkgs, inputs, ... }:
{
  imports =  [
    ./hardware-configuration.nix
    (import ./disko-config.nix {disks = [ "/dev/sda"]; })
  ];

  config = {
    networking.hostName = "nixos-bootstrap";
    networking.hostId = "506a4dd5";
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    environment.systemPackages = with pkgs; [
      git
      vim
    ];
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
        ];
    };
    users.groups.ryan = {
      gid = 1000;
    };
    modules = {
      services = {
        openssh.enable = true;
      };
      system.impermanence.enable = true;
    };
    system.stateVersion = "23.11";
  };
}