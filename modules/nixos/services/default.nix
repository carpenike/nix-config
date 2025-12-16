# Service modules entry point
# Uses category-based imports for maintainability
#
# To import all services (backward compatible):
#   imports = [ ./services ];
#
# To import specific categories (for future lazy loading):
#   imports = [
#     ./services/_categories/media.nix
#     ./services/_categories/downloads.nix
#     ./services/_categories/infrastructure.nix
#   ];
#
# See _categories/default.nix for full category listing
{ ... }:
{
  imports = [
    ./_categories  # Import all service categories
  ];
}
