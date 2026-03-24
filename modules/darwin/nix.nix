_:
{
  # Fix for NixOS 25.05 - Nix build group GID changed from 30000 to 350
  ids.gids.nixbld = 350;

  nix.gc = {
    automatic = true;

    interval = {
      Weekday = 0;
      Hour = 2;
      Minute = 0;
    };
  };

  # nix-daemon is now managed unconditionally by nix-darwin when nix.enable is on

  nix.settings = {
    trusted-users = [ "root" "ryan" ];
    ssl-cert-file = "/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt";
  };
}
