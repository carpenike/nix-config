{ config, pkgs, ... }:
{
  imports =  [ ./hardware-configuration.nix ];
  networking.hostName = "nixos-bootstrap";
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  environment.systemPackages = with pkgs; [
    git
    vim
  ];
  system.stateVersion = "23.11";
}