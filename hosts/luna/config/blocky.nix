let
  ads-whitelist = builtins.toFile "ads-whitelist" ''
    rabobank.nl
  '';
  youtube = builtins.toFile "youtube" ''
    googlevideo.com
    youtu.be
    youtube
    youtube-nocookie.com
    youtube.be
    youtube.co.uk
    youtube.com
    youtube.de
    youtube.fr
    youtube.googleapis.com
    youtube.nl
    youtube.pl
    youtubeeducation.com
    youtubegaming.com
    youtubei.googleapis.com
    youtubekids.com
    yt3.ggpht.com
    ytimg.com
  '';
in
{
  ports = {
    dns = "0.0.0.0:5390";
    http = 4000;
  };
  upstreams.groups.default = [
    # Cloudflare
    "tcp-tls:1.1.1.1:853"
    "tcp-tls:1.0.0.1:853"
  ];

  # configuration of client name resolution
  clientLookup.upstream = "127.0.0.1:5391";

  ecs.useAsClient = true;

  prometheus = {
    enable = true;
    path = "/metrics";
  };

  blocking = {
    loading.downloads.timeout = "4m";
    blackLists = {
      ads = [
        "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
      ];
      fakenews = [
        "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-only/hosts"
      ];
      gambling = [
        "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/gambling-only/hosts"
      ];
      youtube = [
        "file://${youtube}"
      ];
    };

    whiteLists = {
      ads = [
        "file://${ads-whitelist}"
      ];
    };

    clientGroupsBlock = {
      default = [
        "ads"
        "fakenews"
        "gambling"
        "youtube"
      ];
    };
  };
}