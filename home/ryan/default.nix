{ hostname
, ...
}:
{
  imports = [
    ../_modules

    # ./secrets
    ./hosts/${hostname}.nix
  ];

  modules = {

    security = {
      ssh = {
        enable = true;
      };
    };

    shell = {
      # Shell and prompt
      fish.enable = true;

      # Modern CLI tools
      atuin.enable = true;   # Shell history database
      bat.enable = true;     # Syntax-highlighted cat
      direnv.enable = true;  # Per-directory environments
      eza.enable = true;     # Modern ls with git integration
      fzf.enable = true;     # Fuzzy finder
      zoxide.enable = true;  # Smart cd

      git = {
        enable = true;
        username = "Ryan Holt";
        email = "ryan@ryanholt.net";
        signingKey = "2CEA90502F6F3637";
      };
    };

    themes = {
      catppuccin = {
        enable = true;
        flavor = "macchiato";
      };
    };
  };
}
