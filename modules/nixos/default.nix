# NixOS module entry point: base.nix plus the full services tree.
#
# Every host imports everything. Service modules are enable-gated and default
# off, so the import itself is free — measured eval time with all 87 service
# modules vs a 2-category subset is identical (selective category loading was
# removed on that basis; categories remain under services/_categories as
# organized import lists only).
#
# This wrapper exists so we have a single source of truth (base.nix) for the
# OS-level concerns.
{ ... }: {
  imports = [
    ./base.nix
    ./services
  ];
}
