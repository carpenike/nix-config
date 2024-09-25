{
  pkgs,
  ...
}:
{
  imports = [
    ./mutability.nix

    ./deployment
    ./editor
    ./kubernetes
    ./security
    ./shell
    ./themes
    # ./utilities
  ];

  config = {
    home.stateVersion = "23.11";

    programs = {
      home-manager.enable = true;
    };

    xdg.enable = true;

    home.packages = [
      pkgs.home-manager
    ];
  };
}
