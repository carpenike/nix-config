{ pkgs
, lib
, hostname
, ...
}:
let
  itermProfileGuid = "8A4C2CE3-B5A6-4E53-9BD2-21F6D19E889A";

  mkColor = red: green: blue: {
    "Red Component" = red;
    "Green Component" = green;
    "Blue Component" = blue;
    "Alpha Component" = 1;
    "Color Space" = "sRGB";
  };

  # Canonical Catppuccin Macchiato colors from the official iTerm port.
  macchiato = {
    base = mkColor 0.1411764705882353 0.15294117647058825 0.22745098039215686;
    text = mkColor 0.792156862745098 0.8274509803921568 0.9607843137254902;
    rosewater = mkColor 0.9568627450980393 0.8588235294117647 0.8392156862745098;
    sky = mkColor 0.5686274509803921 0.8431372549019608 0.8901960784313725;
    surface1 = mkColor 0.28627450980392155 0.30196078431372547 0.39215686274509803;
    surface2 = mkColor 0.3568627450980392 0.3764705882352941 0.47058823529411764;
    subtext0 = mkColor 0.6470588235294118 0.6784313725490196 0.796078431372549;
    subtext1 = mkColor 0.7215686274509804 0.7529411764705882 0.8784313725490196;
    red = mkColor 0.9294117647058824 0.5294117647058824 0.5882352941176471;
    green = mkColor 0.6509803921568628 0.8549019607843137 0.5843137254901961;
    yellow = mkColor 0.9333333333333333 0.8313725490196079 0.6235294117647059;
    blue = mkColor 0.5411764705882353 0.6784313725490196 0.9568627450980393;
    pink = mkColor 0.9607843137254902 0.7411764705882353 0.9019607843137255;
    teal = mkColor 0.5450980392156862 0.8352941176470589 0.792156862745098;
    brightRed = mkColor 0.9254901960784314 0.4549019607843137 0.5254901960784314;
    brightGreen = mkColor 0.5490196078431373 0.8117647058823529 0.4980392156862745;
    brightYellow = mkColor 0.8823529411764706 0.7764705882352941 0.5098039215686274;
    brightBlue = mkColor 0.47058823529411764 0.6313725490196078 0.9647058823529412;
    brightPink = mkColor 0.9490196078431372 0.6627450980392157 0.8666666666666667;
    brightTeal = mkColor 0.38823529411764707 0.796078431372549 0.7529411764705882;
  };

  itermProfile = {
    Name = "rymac";
    Guid = itermProfileGuid;

    "Normal Font" = "JetBrainsMonoNFM-Regular 14";
    "Use Non-ASCII Font" = false;
    "Draw Powerline Glyphs" = true;
    "ASCII Ligatures" = true;
    "Non-ASCII Ligatures" = true;

    "Ansi 0 Color" = macchiato.surface1;
    "Ansi 1 Color" = macchiato.red;
    "Ansi 2 Color" = macchiato.green;
    "Ansi 3 Color" = macchiato.yellow;
    "Ansi 4 Color" = macchiato.blue;
    "Ansi 5 Color" = macchiato.pink;
    "Ansi 6 Color" = macchiato.teal;
    "Ansi 7 Color" = macchiato.subtext0;
    "Ansi 8 Color" = macchiato.surface2;
    "Ansi 9 Color" = macchiato.brightRed;
    "Ansi 10 Color" = macchiato.brightGreen;
    "Ansi 11 Color" = macchiato.brightYellow;
    "Ansi 12 Color" = macchiato.brightBlue;
    "Ansi 13 Color" = macchiato.brightPink;
    "Ansi 14 Color" = macchiato.brightTeal;
    "Ansi 15 Color" = macchiato.subtext1;
    "Background Color" = macchiato.base;
    "Foreground Color" = macchiato.text;
    "Bold Color" = macchiato.text;
    "Cursor Color" = macchiato.rosewater;
    "Cursor Text Color" = macchiato.base;
    "Cursor Guide Color" = macchiato.text // { "Alpha Component" = 0.07; };
    "Selection Color" = macchiato.surface2;
    "Selected Text Color" = macchiato.text;
    "Link Color" = macchiato.sky;
  };
in
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

    system.defaults.CustomUserPreferences."com.googlecode.iterm2"."Default Bookmark Guid" =
      itermProfileGuid;

    home-manager.users.ryan.home.file."Library/Application Support/iTerm2/DynamicProfiles/rymac.json".text =
      builtins.toJSON { Profiles = [ itermProfile ]; };

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
