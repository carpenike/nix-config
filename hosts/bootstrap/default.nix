{ config, pkgs, ... }:
{
  imports =  [ ./hardware-configuration.nix ];
  networking.hostName = "nixos-bootstrap";
  networking.hostId = "a39fb76a";
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  environment.systemPackages = with pkgs; [
    git
    vim
  ];
  config = {
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
    };
    users.groups.ryan = {
      gid = 1000;
    };

  };

  system.stateVersion = "23.11";
}