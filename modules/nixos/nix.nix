# NixOS-specific nix settings
# Common settings (gc.automatic, gc.options, etc.) are in modules/common/nix.nix
_: {
  # NixOS uses 'dates' for gc scheduling (Darwin uses 'interval')
  nix.gc.dates = "weekly";
}
