{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.modules.services.podman;
in
{
  imports = [
    ./container-base.nix
    ./lib.nix
  ];

  options.modules.services.podman = {
    enable = lib.mkEnableOption "podman";
  };

  config = lib.mkIf cfg.enable {
    modules.services.podman.containerDefaults.enable = true;

    virtualisation = {
      podman = {
        enable = true;
        dockerCompat = true;
        autoPrune.enable = true;
      };
      oci-containers.backend = "podman";
    };
  };
}
