{
  pkgs,
  lib,
  hostname,
  ...
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
      openssh.authorizedKeys.keys = lib.strings.splitString "\n" (builtins.readFile ../../homes/ryan/config/ssh/ssh.pub);
    };

    system.activationScripts.postActivation.text = ''
      # Must match what is in /etc/shells
      sudo chsh -s /run/current-system/sw/bin/fish ryan
    '';

    homebrew = {
      taps = [
      ];
      brews = [
        "cidr"
      ];
      casks = [
        "anylist"
        "discord"
        "google-chrome"
        "halloy"
        "obsidian"
        "orbstack"
        "openscad@snapshot"
        "plex"
        "tableplus"
        "transmit"
        "wireshark"
      ];
      masApps = {
        "1Blocker" = 1365531024;
        "Keka" = 470158793;
        "Passepartout" = 1433648537;
      };
    };
  };
}
