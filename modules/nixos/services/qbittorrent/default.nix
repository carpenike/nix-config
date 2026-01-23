# qBittorrent - BitTorrent download client with VueTorrent WebUI
#
# Factory-based implementation with extensive customization for:
# - VueTorrent alternative WebUI
# - Declarative INI configuration generation
# - BitTorrent port with TCP/UDP support
# - MAC address for stable IPv6 link-local
#
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

let
  # VueTorrent package (pinned for reproducibility)
  vuetorrentPackage = pkgs.fetchzip {
    url = "https://github.com/VueTorrent/VueTorrent/releases/download/v2.31.3/vuetorrent.zip";
    hash = "sha256-Z766fpjcZw4tfJwE1FoNJ/ykDWEFEESqD2zAQXI7tSM=";
    stripRoot = false;
  };
in
mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "qbittorrent";
  description = "BitTorrent download client with VueTorrent WebUI";

  spec = {
    port = 8080;
    image = "lscr.io/linuxserver/qbittorrent:5.0.2";
    category = "downloads";
    displayName = "qBittorrent";
    function = "torrent";

    healthEndpoint = "/api/v2/app/version";
    startPeriod = "60s";

    metricsPath = "/api/v2/app/version";

    # Note: ZFS properties are configured at host level, not in spec
    # The host file sets: modules.storage.datasets.services.qbittorrent = { recordsize = "16K"; ... }

    resources = {
      memory = "2G";
      memoryReservation = "512M";
      cpus = "8.0";
    };

    # Container needs to run as root for LSIO entrypoint (handles PUID/PGID)
    runAsRoot = true;

    # Environment variables
    environment = { cfg, config, ... }: {
      PUID = cfg.user;
      PGID = toString config.users.groups.${cfg.group}.gid;
      TZ = cfg.timezone;
      UMASK = "002";
      WEBUI_PORT = "8080";
    };

    # Volumes - add VueTorrent if enabled
    volumes = cfg:
      [ "${cfg.dataDir}:/config:rw" ]
      ++ lib.optionals (cfg.vuetorrent.enable or false) [
        "${vuetorrentPackage}/vuetorrent:/vuetorrent:ro"
      ];

    # Extra podman options
    extraOptions = { cfg, config }: [
      "--umask=0027"
    ] ++ lib.optionals (cfg.macAddress != null) [
      "--mac-address=${cfg.macAddress}"
    ];

    # Config generator for INI file
    hasConfigGenerator = true;
  };

  # Service-specific options
  extraOptions = {
    torrentPort = lib.mkOption {
      type = lib.types.port;
      default = 6881;
      description = ''
        BitTorrent listening port (TCP and UDP).
        This is the port used for peer connections and DHT.
      '';
      example = 61144;
    };

    vuetorrent = {
      enable = lib.mkEnableOption "VueTorrent alternative WebUI";
      package = lib.mkOption {
        type = lib.types.package;
        default = vuetorrentPackage;
        description = ''
          VueTorrent package to mount into the container.

          Pinned to a specific version for reproducibility.
          Update the URL and hash together when upgrading.

          Check compatibility: https://github.com/VueTorrent/VueTorrent#compatibility
        '';
      };
    };

    settings = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf (oneOf [ str int bool ]));
      default = {
        Application = {
          "FileLogger\\Enabled" = "true";
          "FileLogger\\Path" = "/config/qBittorrent/logs";
          "FileLogger\\MaxSizeBytes" = "66560";
          "FileLogger\\Age" = "1";
          "FileLogger\\AgeType" = "1";
          "FileLogger\\DeleteOld" = "true";
          "FileLogger\\Backup" = "true";
        };
        AutoRun = {
          enabled = "false";
          program = "";
        };
        BitTorrent = {
          "Session\\AddTorrentStopped" = "false";
          "Session\\AnonymousModeEnabled" = "true";
          "Session\\AsyncIOThreadsCount" = "10";
          "Session\\BTProtocol" = "TCP";
          "Session\\DefaultSavePath" = "/data/qb/downloads/";
          "Session\\DHTEnabled" = "false";
          "Session\\DisableAutoTMMByDefault" = "false";
          "Session\\DiskCacheSize" = "-1";
          "Session\\DiskIOReadMode" = "DisableOSCache";
          "Session\\DiskIOType" = "SimplePreadPwrite";
          "Session\\DiskIOWriteMode" = "EnableOSCache";
          "Session\\DiskQueueSize" = "65536";
          "Session\\Encryption" = "0";
          "Session\\ExcludedFileNames" = "";
          "Session\\FilePoolSize" = "40";
          "Session\\GlobalDLSpeedLimit" = "81920";
          "Session\\HashingThreadsCount" = "2";
          "Session\\Interface" = "eth0";
          "Session\\LSDEnabled" = "false";
          "Session\\PeXEnabled" = "false";
          "Session\\QueueingSystemEnabled" = "true";
          "Session\\ResumeDataStorageType" = "SQLite";
          "Session\\SSL\\Port" = "57024";
          "Session\\ShareLimitAction" = "Stop";
          "Session\\TempPath" = "/data/qb/incomplete/";
          "Session\\UseAlternativeGlobalSpeedLimit" = "false";
          "Session\\UseOSCache" = "true";
          "Session\\UseRandomPort" = "false";
        };
        Core = {
          "AutoDeleteAddedTorrentFile" = "Never";
        };
        LegalNotice = {
          Accepted = "true";
        };
        Meta = {
          MigrationVersion = "8";
        };
        Network = {
          "PortForwardingEnabled" = "false";
          "Proxy\\HostnameLookupEnabled" = "false";
          "Proxy\\Profiles\\BitTorrent" = "true";
          "Proxy\\Profiles\\Misc" = "true";
          "Proxy\\Profiles\\RSS" = "true";
        };
        Preferences = {
          "Advanced\\AnonymousMode" = "true";
          "Advanced\\RecheckOnCompletion" = "false";
          "Advanced\\trackerPort" = "9000";
          "Advanced\\trackerPortForwarding" = "false";
          "Bittorrent\\DHT" = "false";
          "Bittorrent\\Encryption" = "0";
          "Bittorrent\\LSD" = "false";
          "Bittorrent\\PeX" = "false";
          "Connection\\ResolvePeerCountries" = "true";
          "Connection\\UPnP" = "false";
          "Connection\\alt_speeds_on" = "false";
          "Downloads\\SavePath" = "/data/qb/downloads/";
          "Downloads\\TempPath" = "/data/qb/incomplete/";
          "General\\Locale" = "en";
          "General\\UseRandomPort" = "false";
          "Queueing\\MaxActiveDownloads" = "5";
          "Queueing\\MaxActiveTorrents" = "100";
          "Queueing\\MaxActiveUploads" = "10";
          "Queueing\\QueueingEnabled" = "true";
          "WebUI\\Address" = "*";
          "WebUI\\AlternativeUIEnabled" = "true";
          "WebUI\\AuthSubnetWhitelist" = "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16";
          "WebUI\\AuthSubnetWhitelistEnabled" = "true";
          "WebUI\\CSRFProtection" = "false";
          "WebUI\\HostHeaderValidation" = "false";
          "WebUI\\LocalHostAuth" = "false";
          "WebUI\\Port" = "8080";
          "WebUI\\RootFolder" = "/vuetorrent";
          "WebUI\\ServerDomains" = "*";
          "WebUI\\SessionTimeout" = "3600";
          "WebUI\\UseUPnP" = "false";
        };
        RSS = {
          "AutoDownloader\\DownloadRepacks" = "true";
          "AutoDownloader\\SmartEpisodeFilter" = "s(\\\\d+)e(\\\\d+), (\\\\d+)x(\\\\d+), \"(\\\\d{4}[.\\\\-]\\\\d{1,2}[.\\\\-]\\\\d{1,2})\", \"(\\\\d{1,2}[.\\\\-]\\\\d{1,2}[.\\\\-]\\\\d{4})\"";
        };
      };
      description = ''
        Declarative settings for qBittorrent.conf.

        These settings are used to generate the configuration file on the first run
        or after the configuration file has been manually deleted.

        This "Declarative Initial Seeding" approach allows for:
        - Reproducible initial setup (version controlled in Git)
        - WebUI remains fully functional for runtime changes
        - Easy disaster recovery (delete config file, restart service)
        - Intentional updates (delete config to apply new Nix defaults)

        Note: Username and Password are not included here to avoid storing
        credentials in the Nix store. qBittorrent will use defaults on first
        run, which can then be changed through the WebUI.
      '';
    };
  };

  # Service-specific configuration
  extraConfig = cfg: {
    # Add torrent port to extraPorts with TCP/UDP
    modules.services.qbittorrent.extraPorts = [
      { port = cfg.torrentPort; protocol = "both"; container = true; }
    ];

    # Inject torrent port into settings dynamically
    modules.services.qbittorrent.settings = lib.mkMerge [
      {
        BitTorrent."Session\\Port" = toString cfg.torrentPort;
        Preferences."Connection\\PortRangeMin" = toString cfg.torrentPort;
      }
    ];

    # Config generator script for INI file
    modules.services.qbittorrent.configGenerator.script = ''
            set -eu
            CONFIG_FILE="${cfg.dataDir}/qBittorrent/qBittorrent.conf"
            CONFIG_DIR=$(dirname "$CONFIG_FILE")

            # Only generate if config doesn't exist
            if [ ! -f "$CONFIG_FILE" ]; then
              echo "Config missing, generating from Nix settings..."
              mkdir -p "$CONFIG_DIR"

              # Generate config using toINI
              cat > "$CONFIG_FILE" << 'INIEOF'
      ${lib.generators.toINI { } cfg.settings}
      INIEOF

              chmod 640 "$CONFIG_FILE"
              echo "Configuration generated at $CONFIG_FILE"
            else
              echo "Config exists at $CONFIG_FILE, preserving existing file"
            fi
    '';
  };
}
