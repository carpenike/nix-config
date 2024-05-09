{ lib, config, pkgs, ... }:
{
  imports =  [ ./hardware-configuration.nix ];
  networking.hostName = "nixos-bootstrap";
  networking.hostId = "a39fb76a";
  config = {
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
    };
  };
  system.stateVersion = "23.11";
}