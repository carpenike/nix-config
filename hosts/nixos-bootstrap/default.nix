# hosts/nixos-bootstrap/default.nix
{ lib, config, pkgs, inputs
, disks ? [ "/dev/nvme0n1" ]
, ... }:
{
  _module.args.disks = disks;

  imports = [
    ./disko-config.nix
    # Skip hardware-configuration.nix - disko handles it
  ];

  # Bare minimum for bootstrap
  networking.hostName = "nixos-bootstrap";
  networking.hostId = "506a4dd5";

  # ZFS essentials
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Network (DHCP usually fine for bootstrap)
  networking.useDHCP = lib.mkDefault true;

  # SSH for remote access
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";  # Temporary for bootstrap
  };

  # Your user
  users.users.ryan = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [
      (builtins.readFile ../../home/ryan/config/ssh/ssh.pub)
    ];
  };

  # Allow sudo without password during bootstrap
  security.sudo.wheelNeedsPassword = false;

  # Minimal packages
  environment.systemPackages = with pkgs; [ git vim ];

  system.stateVersion = "23.11";
}
