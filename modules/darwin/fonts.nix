{ pkgs
, ...
}:
{
  fonts = {
    packages = with pkgs; [
      # Nerd Fonts (with icons for terminal prompts)
      nerd-fonts.jetbrains-mono # Recommended - great for coding
      nerd-fonts.fira-code # Ligatures support
      nerd-fonts.hack # Clean and readable
      nerd-fonts.meslo-lg # macOS default terminal font, nerdfied

      # Other fonts
      font-awesome
      monaspace
    ];
  };
}
