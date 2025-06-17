{
  pkgs,
  ...
}:
{
  fonts = {
    packages = with pkgs; [
      nerd-fonts.fira-code
      font-awesome
      monaspace
    ];
  };
}
