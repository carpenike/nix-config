_:
{
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = false; # Don't update during rebuild
      # nix-darwin-26.05 includes the Homebrew 7 fix (bb9c29c), so "zap" now
      # emits `--zap --force-cleanup` itself; the 25.11 extraFlags workaround
      # has been retired.
      cleanup = "zap";
      upgrade = false; # Keep rebuilds independent of App Store updates
    };
    global = {
      brewfile = true; # Run brew bundle from anywhere
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
