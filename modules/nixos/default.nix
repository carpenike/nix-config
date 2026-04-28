# Backwards-compatible NixOS module entry point.
#
# Imports everything from base.nix plus the full services tree. This is the
# legacy "all services" path used by hosts that don't pass `serviceCategories`
# in mkNixosSystem (currently: nixos-bootstrap, nas-0, nas-1).
#
# Hosts that opt into selective category loading import `base.nix` directly
# from `lib/mkSystem.nix` and then add the categories they need.
#
# This wrapper exists so we have a single source of truth (base.nix) for the
# OS-level concerns and don't drift between the two entry points.
{ ... }: {
  imports = [
    ./base.nix
    ./services
  ];
}
