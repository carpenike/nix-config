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
    # FIXME: Circular dependency - database-interface.nix defines options.modules.services.postgresql.databases
    # but postgresql/default.nix defines options.modules.services.postgresql as attrsOf submodule
    # These conflict - need to move databases option inside the submodule
    # ./services/postgresql/database-interface.nix  # PostgreSQL database interface (option declaration only)
    ./postgresql-preseed.nix  # PostgreSQL automatic pre-seeding for new servers
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
