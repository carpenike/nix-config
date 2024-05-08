{
  pkgs,
  lib,
  config,
  hostname,
  ...
}:
let
  ifGroupsExist = groups: builtins.filter (group: builtins.hasAttr group config.users.groups) groups;
in
{
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
  ];

  config = {
    networking = {
      hostName = hostname;
      hostId = "9fe3ff83";
      useDHCP = true;
      firewall.enable = false;
    };

    users.users.ryan = {
      uid = 1000;
      name = "ryan";
      home = "/home/ryan";
      group = "ryan";
      shell = pkgs.fish;
      openssh.authorizedKeys.keys = lib.strings.splitString "\n" (builtins.readFile ../../home/ryan/config/ssh/ssh.pub);
      isNormalUser = true;
      extraGroups =
        [
          "wheel"
          "users"
        ]
        ++ ifGroupsExist [
          "network"
        ];
    };
    users.groups.ryan = {
      gid = 1000;
    };

    system.activationScripts.postActivation.text = ''
      # Must match what is in /etc/shells
      chsh -s /run/current-system/sw/bin/fish ryan
    '';

    modules = {
      services = {
        bind = {
          enable = true;
          config = import ./config/bind.nix {inherit config;};
        };

        adguardhome = {
          enable = true;
          package = pkgs.adguardhome;
          settings = {
            bind_host = "0.0.0.0";
            bind_port = 3000;
            dns = {
              bind_host = "127.0.0.1";
              port = 5390;
              bootstrap_dns = [
                # quad9
                "9.9.9.10"
                "149.112.112.10"
                "2620:fe::10"
                "2620:fe::fe:10"

                # cloudflare
                "1.1.1.1"
                "2606:4700:4700::1111"
              ];
              upstream_dns = [
                "[/holthome.net/]127.0.0.1:5390"
                "[/ryho.lt/]127.0.0.1:5390"
                "[/in-addr.arpa/]127.0.0.1:5390"
                "[/ip6.arpa/]127.0.0.1:5390"
                "https://1.1.1.1/dns-query"
              ];
              upstream_mode = "load_balance";
              fallback_dns = [
                "https://dns.cloudflare.com/dns-query"
              ];
              local_ptr_upstreams = [ "127.0.0.1:5390" ];
              use_private_ptr_resolvers = true;

              # security
              enable_dnsseec = true;

              # local cache settings
              cache_size = 100000000;
              cache_ttl_min = 60;
              cache_optimistic = true;

              theme = "auto";
            };
            filters = 
              let
                urls = [
                  { name = "AdGuard DNS filter"; url = "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"; }
                  { name = "AdAway Default Blocklist"; url = "https://adaway.org/hosts.txt"; }
                  { name = "Big OSID"; url = "https://big.oisd.nl"; }
                  { name = "1Hosts Lite"; url = "https://o0.pages.dev/Lite/adblock.txt"; }
                  { name = "hagezi multi pro"; url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt"; }
                  { name = "osint"; url = "https://osint.digitalside.it/Threat-Intel/lists/latestdomains.txt"; }
                  { name = "phishing army"; url = "https://phishing.army/download/phishing_army_blocklist_extended.txt"; }
                  { name = "notrack malware"; url = "https://gitlab.com/quidsup/notrack-blocklists/raw/master/notrack-malware.txt"; }
                  { name = "EasyPrivacy"; url = "https://v.firebog.net/hosts/Easyprivacy.txt"; }
                ];
                buildList = id: url: {
                   enabled = true;
                   inherit id;
                   inherit (url) name;
                   inherit (url) url;
                 };
              in
                lib.imap1 buildList urls;
            

            clients = {
              runtime_sources = {
                whois = true;
                arp = true;
                rdns = true;
                dhcp = true;
                hosts = true;
              };
              persistent = [ 
                {
                  name = "Caydan";
                  safe_search = {
                    enabled = true;
                    bing = true;
                    duckduckgo = true;
                    google = true;
                    pixabay = true;
                    yandex = true;
                    youtube = true;
                  };
                  blocked_services = {
                    schedule = {
                      time_zone = "UTC";
                    };
                    ids = [
                      # "4chan"
                      # "500px"
                      # "9gag"
                      # "activision_blizzard"
                      # "aliexpress"
                      # "amazon"
                      # "amazon_streaming"
                      # "amino"
                      # "apple_streaming"
                      # "battle_net"
                      # "betano"
                      # "betfair"
                      # "betway"
                      # "bigo_live"
                      # "bilibili"
                      # "blaze"
                      # "blizzard_entertainment"
                      # "bluesky"
                      # "box"
                      # "canaisglobo"
                      # "claro"
                      # "cloudflare"
                      # "clubhouse"
                      # "coolapk"
                      # "crunchyroll"
                      # "dailymotion"
                      # "deezer"
                      # "directvgo"
                      # "discord"
                      # "discoveryplus"
                      # "disneyplus"
                      # "douban"
                      # "dropbox"
                      "ebay"
                      "electronic_arts"
                      "epic_games"
                      "espn"
                      "facebook"
                      "fifa"
                      "flickr"
                      "globoplay"
                      "gog"
                      "hbomax"
                      "hulu"
                      "icloud_private_relay"
                      "iheartradio"
                      "imgur"
                      "instagram"
                      "iqiyi"
                      # "kakaotalk"
                      # "kik"
                      # "kook"
                      # "lazada"
                      # "leagueoflegends"
                      # "line"
                      # "linkedin"
                      # "lionsgateplus"
                      # "looke"
                      # "mail_ru"
                      # "mastodon"
                      # "mercado_libre"
                      # "minecraft"
                      # "nebula"
                      # "netflix"
                      # "nintendo"
                      # "ok"
                      # "olvid"
                      # "onlyfans"
                      # "origin"
                      # "paramountplus"
                      # "pinterest"
                      # "playstation"
                      # "plenty_of_fish"
                      # "plex"
                      # "pluto_tv"
                      # "privacy"
                      # "qq"
                      # "rakuten_viki"
                      # "reddit"
                      # "riot_games"
                      # "roblox"
                      # "rockstar_games"
                      # "samsung_tv_plus"
                      # "shein"
                      # "shopee"
                      # "signal"
                      # "skype"
                      # "snapchat"
                      # "soundcloud"
                      # "spotify"
                      # "steam"
                      # "telegram"
                      # "temu"
                      # "tidal"
                      # "tiktok"
                      # "tinder"
                      # "tumblr"
                      # "twitch"
                      # "twitter"
                      # "ubisoft"
                      # "valorant"
                      # "viber"
                      # "vimeo"
                      # "vk"
                      # "voot"
                      # "wargaming"
                      # "wechat"
                      # "weibo"
                      # "whatsapp"
                      # "wizz"
                      # "xboxlive"
                      # "xiaohongshu"
                      # "youtube"
                      # "yy"
                      # "zhihu"
                    ];
                  };
                  ids = [
                    "10.30.50.252"
                  ];
                  tags = [
                    "device_tablet"
                    "os_ios"
                    "user_child"
                  ];
                  upstreams = [
                    "https://1.1.1.3/dns-query"
                  ];
                  use_global_settings = false;
                  filtering_enabled = true;
                  parental_enabled = true;
                  safebrowsing_enabled = true;
                  use_global_blocked_services = false;
                  ignore_querylog = false;
                  ignore_statistics = false;
  
                }
              ];
            };
          };
        };

        chrony = {
          enable = true;
          servers = [
            "0.us.pool.ntp.org"
            "1.us.pool.ntp.org"
            "2.us.pool.ntp.org"
            "3.us.pool.ntp.org"
          ];
        };

        dnsdist = {
          enable = true;
          config = builtins.readFile ./config/dnsdist.conf;
        };

        node-exporter.enable = true;

        # onepassword-connect = {
        #   enable = true;
        #   credentialsFile = config.sops.secrets.onepassword-credentials.path;
        # };

        openssh.enable = true;
      };

      users = {
        groups = {
          admins = {
            gid = 991;
            members = [
              "ryan"
            ];
          };
        };
      };
    };

    # Use the systemd-boot EFI boot loader.
    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
  };
}
