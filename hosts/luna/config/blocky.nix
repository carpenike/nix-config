let
  ads-whitelist = builtins.toFile "ads-whitelist" ''
    google.com
  '';
  youtube = builtins.toFile "youtube" ''
    ||youtube.it^
    ||youtube.jo^
    ||youtube.jp^
    ||youtube.kr^
    ||youtube.kz^
    ||youtube.la^
    ||youtube.lk^
    ||youtube.lt^
    ||youtube.lu^
    ||youtube.lv^
    ||youtube.ly^
    ||youtube.ma^
    ||youtube.md^
    ||youtube.me^
    ||youtube.mk^
    ||youtube.mn^
    ||youtube.mx^
    ||youtube.my^
    ||youtube.ng^
    ||youtube.ni^
    ||youtube.nl^
    ||youtube.no^
    ||youtube.pa^
    ||youtube.pe^
    ||youtube.ph^
    ||youtube.pk^
    ||youtube.pl^
    ||youtube.pr^
    ||youtube.pt^
    ||youtube.qa^
    ||youtube.ro^
    ||youtube.rs^
    ||youtube.ru^
    ||youtube.sa^
    ||youtube.se^
    ||youtube.sg^
    ||youtube.si^
    ||youtube.sk^
    ||youtube.sn^
    ||youtube.soy^
    ||youtube.sv^
    ||youtube.tn^
    ||youtube.tv^
    ||youtube.ua^
    ||youtube.ug^
    ||youtube.uy^
    ||youtube.vn^
    ||youtubeeducation.com^
    ||youtubeembeddedplayer.googleapis.com^
    ||youtubefanfest.com^
    ||youtubegaming.com
    ||youtubego.co.id^
    ||youtubego.co.in^
    ||youtubego.com^
    ||youtubego.com.br^
    ||youtubego.id^
    ||youtubego.in^
    ||youtubei.googleapis.com^
    ||youtubekids.com^
    ||youtubemobilesupport.com^
    ||yt.be^
    ||ytimg.com^
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
      facebook = [
        "https://raw.githubusercontent.com/jmdugan/blocklists/master/corporations/facebook/all"
        "https://www.github.developerdan.com/hosts/lists/facebook-extended.txt"
        "https://raw.githubusercontent.com/anudeepND/blacklist/master/facebook.txt"
      ];
      twitter = [
        "https://raw.githubusercontent.com/jmdugan/blocklists/master/corporations/twitter/all"
      ];
      # Temporary till https://github.com/jmdugan/blocklists/pull/97 is merged
      tiktok = [
        "https://raw.githubusercontent.com/drduh/blocklists/wip-tiktok/corporations/tiktok/all"
      ];
      # Temporary till https://github.com/jmdugan/blocklists/pull/89 is merged
      reddit = [
        "https://raw.githubusercontent.com/shff/blocklists/block-reddit/corporations/reddit/all"
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
      ];
      "caydans-ipad.holthome.net" = [
        "ads"
        "fakenews"
        "gambling"
        "youtube"
        "facebook"
        "twitter"
        "tiktok"
        "reddit"
      ];
      "taylors-ipad.holthome.net" = [
        "ads"
        "fakenews"
        "gambling"
        "youtube"
        "facebook"
        "twitter"
        "tiktok"
        "reddit"
      ];
      "ryans-iphone.holthome.net" = [
        "ads"
        "fakenews"
        "gambling"
      ];
    };
  };
}
