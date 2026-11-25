_:
{
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = false; # Don't update during rebuild
      # Report-only (2026-11-25): a switch never uninstalls anything.
      # The previous `--force-cleanup --zap` removed every undeclared cask AND
      # its data on each switch, which took 1Password off this Mac once.
      # See what a cleanup would remove with:  brew bundle cleanup
      # and remove it yourself with:           brew bundle cleanup --force
      # (HOMEBREW_BUNDLE_FILE, set by global.brewfile, points at the declared list.)
      # Don't restore cleanup = "zap" (or "uninstall") as an automatic step.
      cleanup = "none";
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
