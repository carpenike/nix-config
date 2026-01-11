{ pkgs
, lib
, hostname
, ...
}:
{
  config = {
    networking = {
      computerName = "Ryan's MacBook";
      hostName = hostname;
      localHostName = hostname;
    };

    users.users.ryan = {
      name = "ryan";
      home = "/Users/ryan";
      shell = pkgs.fish;
      openssh.authorizedKeys.keys = lib.strings.splitString "\n" (builtins.readFile ../../home/ryan/config/ssh/ssh.pub);
    };

    system.activationScripts.postActivation.text = ''
      # Must match what is in /etc/shells
      sudo chsh -s /run/current-system/sw/bin/fish ryan
    '';

    homebrew = {
      taps = [
      ];
      brews = [
        "cidr" # Not available in nixpkgs yet
      ];
      casks = [
        "anylist"
        "discord"
        "halloy"
        "obsidian"
        "orbstack"
        "plex"
        "spotify"
        "tableplus"
        "transmit"
        "microsoft-edge"
        "gpg-suite-pinentry"
      ];
      masApps = { };
    };
  };
}
