{ pkgs
, ...
}:
{
  # Include both bash and fish in /etc/shells
  # - bash: Required as login shell for VS Code Remote SSH compatibility
  # - fish: Interactive shell launched by bash for terminal sessions
  environment.shells = with pkgs; [ bash fish ];

  programs = {
    fish = {
      enable = true;
      vendor = {
        completions.enable = true;
        config.enable = true;
        functions.enable = true;
      };
    };
  };
}
