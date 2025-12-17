# Media automation and profile sync services
# Import this category alongside media for automation features
{ ... }:
{
  imports = [
    ../dispatcharr # Dispatcharr IPTV management
    ../profilarr # Quality profile sync
    ../recyclarr # TRaSH Guides automation
  ];
}
