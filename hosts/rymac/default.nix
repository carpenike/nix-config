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
        "jadx"
      ];
      casks = [
        "android-platform-tools"
        "anylist"
        "copilot-cli"
        # "discord" -- self-updating
        "gpg-suite-pinentry"
        "halloy"
        "mitmproxy"
        "obsidian"
        "signal"
        # "orbstack" -- self-updating, license management better standalone
        # "plex" -- self-updating
        # "spotify" -- self-updating
        # "tableplus" -- self-updating, license tied to install
        # "transmit" -- self-updating, Panic manages updates well
      ];
      masApps = {
        "1Password for Safari" = 1569813296;
        "GarageBand" = 682658836;
        "iMovie" = 408981434;
        "Keynote" = 409183694;
        "Numbers" = 409203825;
        "Pages" = 409201541;
        "PerformanceTest" = 1560051043;
        "Slack" = 803453959;
        "Windows App" = 1295203466;
      };
    };
  };
}
