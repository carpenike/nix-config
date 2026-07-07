# Service modules entry point
#
# Imports every service category unconditionally; individual services are
# gated behind their own `modules.services.<name>.enable` options.
# See _categories/default.nix for the category listing.
{ ... }:
{
  imports = [
    ./_categories # Import all service categories
  ];
}
