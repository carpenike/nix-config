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
        # Enable socket for secure monitoring access
        dockerSocket.enable = true;
      };
      oci-containers.backend = "podman";
    };

    # Use the correct NixOS override pattern - extend rather than replace
    systemd.sockets.podman = {
      wantedBy = lib.mkForce [ "sockets.target" ];
      socketConfig = lib.mkMerge [
        (lib.mkIf config.virtualisation.podman.dockerSocket.enable {
          SocketGroup = lib.mkForce "podman-socket";
        })
      ];
    };
  };
}
