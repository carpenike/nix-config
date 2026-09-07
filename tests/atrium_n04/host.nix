{ ... }:
{
  imports = [ ../../hosts/forge/atrium/litellm-controller-isolated.nix ];
  networking.hostName = "atrium-n04-fixture";
  networking.firewall.allowedTCPPorts = [ ];
  boot.loader.grub.enable = false;
  fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
  system.stateVersion = "25.11";
}
