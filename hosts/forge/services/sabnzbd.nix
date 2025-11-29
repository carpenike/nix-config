{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.sabnzbd.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.sabnzbd = {
        enable = true;

        # Use home-operations container image (version 4.5.5)
        # Pinned with SHA256 digest for immutability
        image = "ghcr.io/home-operations/sabnzbd:4.5.5@sha256:da57e01cdebc547852b6df85c8df8c0e4d87792742c7608c5590dc653b184e8c";

        # Override default port (8081 already in use on this host)
        port = 8082;

        # Use unified /data mount (same as Sonarr/Radarr/qBittorrent for hardlinks)
        # Structure: /mnt/data/sab/{incomplete,complete/{sonarr,radarr,readarr,lidarr}}
        # This allows all services to see the same paths for atomic moves/hardlinks
        nfsMountDependency = "media"; # Use shared NFS mount (auto-configures downloadsDir to /mnt/data)
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Pre-configured categories (unlike qBittorrent's dynamic approach)
        # SABnzbd categories control final output directory via lookup rules
        categories = {
          sonarr = { dir = "sonarr"; priority = "0"; };
          radarr = { dir = "radarr"; priority = "0"; };
          readarr = { dir = "readarr"; priority = "0"; };
          lidarr = { dir = "lidarr"; priority = "0"; };
        };

        # Allow *arr services to connect to SABnzbd API
        extraHostWhitelist = [ "sonarr" "radarr" "readarr" "lidarr" "sabnzbd.holthome.net" ];

        # Declarative API key management via sops-nix (matches *arr pattern)
        apiKeyFile = config.sops.secrets."sabnzbd/api-key".path;

        # Declarative Usenet provider configuration
        usenetProviders = {
          newsgroup-ninja = {
            host = "news-us.newsgroup.ninja";
            port = 563;
            connections = 8;
            ssl = true;
            retention = 0;
            priority = 0;
            usernameFile = config.sops.secrets."sabnzbd/usenet/username".path;
            passwordFile = config.sops.secrets."sabnzbd/usenet/password".path;
          };
        };

        # Critical operational settings (Gemini Pro recommendations)
        fixedPorts = true; # CRITICAL: Prevent silent port changes on boot
        enableHttpsVerification = true; # SECURITY: MITM protection for updates/RSS
        cacheLimit = "2G"; # forge has 32GB RAM, can afford 2G cache
        bandwidthPercent = 90; # 90% to leave headroom for Plex/SSH
        queueLimit = 50; # Higher limit for bulk *arr operations
        logLevel = 1; # Info level for operational visibility

        reverseProxy = {
          enable = true;
          hostName = "sabnzbd.holthome.net";
          caddySecurity = forgeDefaults.caddySecurity.media;
        };

        backup = forgeDefaults.mkBackupWithSnapshots "sabnzbd";

        notifications.enable = true;

        # Use syncoid/local only - preserve ZFS lineage, use Restic only for manual DR
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration for SABnzbd dataset
      # Contributes to host-level Sanoid configuration following the contribution pattern
      # NOTE: Downloads are NOT backed up (transient data on NFS)
      modules.backup.sanoid.datasets."tank/services/sabnzbd" =
        forgeDefaults.mkSanoidDataset "sabnzbd";

      # Service-specific monitoring alerts
      # Contributes to host-level alerting configuration following the contribution pattern
      modules.alerting.rules."sabnzbd-service-down" =
        forgeDefaults.mkServiceDownAlert "sabnzbd" "Sabnzbd" "usenet download";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.sabnzbd = {
        group = "Downloads";
        name = "SABnzbd";
        icon = "sabnzbd";
        href = "https://sabnzbd.holthome.net";
        description = "Usenet Client";
        siteMonitor = "http://localhost:8082";
        widget = {
          type = "sabnzbd";
          url = "http://localhost:8082";
          key = "{{HOMEPAGE_VAR_SABNZBD_API_KEY}}";
        };
      };
    })
  ];
}
