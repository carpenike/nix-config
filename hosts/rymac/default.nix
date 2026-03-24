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
        "copilot-cli"
        # "discord" -- self-updating
        "halloy"
        "obsidian"
        "signal"
        # "orbstack" -- self-updating, license management better standalone
        # "plex" -- self-updating
        # "spotify" -- self-updating
        # "tableplus" -- self-updating, license tied to install
        # "transmit" -- self-updating, Panic manages updates well
        "gpg-suite-pinentry"
      ];
      masApps = { };
    };
  };
}
