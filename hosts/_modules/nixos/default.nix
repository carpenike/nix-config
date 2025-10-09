{
  lib,
  ...
}: {
  imports = [
    ./doas.nix
    ./impermanence.nix
    ./nix.nix
    ./users.nix
    ./systemd.nix
    ./filesystems
    ./hardware
    ./services
    ./services/attic.nix
    ./backup.nix
    ./services/backup-services.nix
    ./monitoring.nix
    ./notifications
    ./system-notifications.nix
    ./storage  # Import storage module (includes datasets.nix and nfs-mounts.nix)
  ];

  documentation.nixos.enable = false;

  # Increase open file limit for sudoers
  security.pam.loginLimits = [
    {
      domain = "@wheel";
      item = "nofile";
      type = "soft";
      value = "524288";
    }
    {
      domain = "@wheel";
      item = "nofile";
      type = "hard";
      value = "1048576";
    }
  ];

  system = {
    # Use mkDefault so individual hosts can override this value
    # Each host should set its stateVersion to the NixOS version it was first installed with
    stateVersion = lib.mkDefault "23.11";
  };
}
