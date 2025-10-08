# hosts/nixos-bootstrap/default.nix
{ lib, config, pkgs, ... }:
{
  # ✅ Provide disks to imported modules
  _module.args.disks = [ "/dev/disk/by-id/nvme-Samsung_SSD_950_PRO_512GB_S2GMNX0H803986M" "/dev/disk/by-id/nvme-WDS100T3X0C-00SJG0_200278801343" ];

  imports = [
    ./disko-config.nix
  ];

  # Bare minimum for bootstrap
  networking.hostName = "nixos-bootstrap";
  networking.hostId = "1b3031e7";

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
