_:
{
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = false; # Don't update during rebuild
      # WORKAROUND (2026-09-23): nix-darwin 25.11 emits Homebrew's removed --cleanup.
      # Affects: Darwin activation with Homebrew 7.
      # Upstream: https://github.com/nix-darwin/nix-darwin/commit/bb9c29c19327336fa499fe77bd7ba6d00ccec484
      # Check: Restore cleanup = "zap" and remove extraFlags once our input includes the fix.
      cleanup = "none";
      extraFlags = [ "--force-cleanup" "--zap" ];
      upgrade = false; # Keep rebuilds independent of App Store updates
    };
    global = {
      brewfile = true; # Run brew bundle from anywhere
      lockfiles = false; # Don't save lockfile (since running from anywhere)
    };
    taps = [
    ];
    brews = [
    ];
    casks = [
      "1password"
      "gifox"
      "iterm2"
      "jordanbaird-ice"
      "raycast"
      "shottr"
      # "slack" -- self-updating, remove from Homebrew management
    ];
    masApps = {
      "Caffeinated" = 1362171212;
    };
  };
}
