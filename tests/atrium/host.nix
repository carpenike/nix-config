{ atrium, config, ... }:
{
  imports = [ atrium.nixosModules.atrium ];

  networking.hostName = "atrium-fixture";
  boot.loader.grub.enable = false;
  fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
  system.stateVersion = "25.11";

  services.atrium = {
    enable = true;
    registry = import ./registry.nix { inherit atrium; };
  };

  assertions = [
    {
      assertion = config.networking.hostName == "atrium-fixture";
      message = "ATR-N02 declarations are only for the isolated fixture, never a live host.";
    }
    {
      assertion = !config.services.atrium.runtime.resolver.enable
        && !config.services.atrium.runtime.reconciler.enable;
      message = "ATR-N02 fixture publishes/evaluates policy only; executable integration belongs to later tickets.";
    }
  ];
}
