_:
{
  nix.gc = {
    automatic = true;

    interval = {
      Weekday = 0;
      Hour = 2;
      Minute = 0;
    };
  };

  # nix-daemon is now managed unconditionally by nix-darwin when nix.enable is on
}
