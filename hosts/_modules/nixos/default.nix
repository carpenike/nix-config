{
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
    stateVersion = "23.11";
  };
}
