# SABnzbd - Usenet download client
#
# Factory-based implementation with extensive customization for:
# - Declarative Usenet provider configuration (credentials via sops)
# - Pre-configured categories for *arr integration
# - TRaSH Guides best practices for config generation
# - Critical operational settings (fixed ports, cache limits, etc.)
#
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "sabnzbd";
  description = "Usenet download client";

  spec = {
    # Host port 8081 -> Container port 8080
    port = 8081;
    containerPort = 8080;

    # Default to home-operations image per ADR-005
    image = "ghcr.io/home-operations/sabnzbd:latest";
    category = "downloads";
    displayName = "SABnzbd";
    function = "usenet";

    healthEndpoint = "/api?mode=version";
    startPeriod = "60s";

    metricsPath = "/api?mode=version";

    zfsRecordSize = "16K";
    zfsCompression = "zstd";

    resources = {
      memory = "1G";
      memoryReservation = "512M";
      cpus = "4.0";
    };

    # home-operations images run as non-root user directly (via --user flag)
    runAsRoot = false;

    # Skip default /config mount - we need custom volume mapping
    skipDefaultConfigMount = true;

    # Volumes - map dataDir:/config and downloadsDir:/data
    volumes = cfg: [
      "${cfg.dataDir}:/config:rw"
      "${cfg.downloadsDir}:/data:rw"
    ];

    # Config generator for sabnzbd.ini
    hasConfigGenerator = true;
  };

  # Service-specific options beyond standard factory options
  extraOptions = {
    extraHostWhitelist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Additional hostnames to add to SABnzbd's `host_whitelist`.
        This is critical for allowing *arr services (running in other containers)
        to communicate with SABnzbd. Add your *arr container names here.
      '';
      example = [ "sonarr" "radarr" "readarr" "lidarr" ];
    };

    categories = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          dir = lib.mkOption {
            type = lib.types.str;
            description = ''
              Relative path from completed downloads directory where files for this category will be placed.
              This is relative to downloadsDir/complete/.
            '';
            example = "sonarr";
          };
          priority = lib.mkOption {
            type = lib.types.enum [ "-100" "0" "100" ];
            default = "0";
            description = ''
              Download priority for this category.
              -100 = Low, 0 = Normal, 100 = High
            '';
          };
        };
      });
      default = {
        sonarr = { dir = "sonarr"; priority = "0"; };
        radarr = { dir = "radarr"; priority = "0"; };
        readarr = { dir = "readarr"; priority = "0"; };
        lidarr = { dir = "lidarr"; priority = "0"; };
      };
      description = ''
        Pre-configured categories for SABnzbd.
        Unlike qBittorrent's dynamic categories, SABnzbd categories should be pre-configured
        as they control the final output directory via lookup rules.

        The *arr services pass a category string, and SABnzbd uses it to determine
        the final save path, making this a more centralized and robust configuration.
      '';
    };

    usenetProviders = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          host = lib.mkOption {
            type = lib.types.str;
            description = "Usenet provider hostname";
            example = "news-us.newsgroup.ninja";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 563;
            description = "Usenet provider port (563 for SSL, 119 for plain)";
          };
          connections = lib.mkOption {
            type = lib.types.int;
            default = 8;
            description = "Maximum number of connections to this server";
          };
          ssl = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Use SSL/TLS connection";
          };
          priority = lib.mkOption {
            type = lib.types.int;
            default = 0;
            description = "Server priority (0 = primary, higher = backup)";
          };
          retention = lib.mkOption {
            type = lib.types.int;
            default = 0;
            description = "Server retention in days (0 = unknown/unlimited)";
          };
          usernameFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing Usenet username (via sops)";
          };
          passwordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing Usenet password (via sops)";
          };
        };
      });
      default = { };
      description = ''
        Declarative Usenet provider configuration.
        Credentials are managed via sops-nix for secure storage and disaster recovery.
      '';
      example = {
        newsgroup-ninja = {
          host = "news-us.newsgroup.ninja";
          port = 563;
          connections = 8;
          ssl = true;
        };
      };
    };

    # Critical operational settings (TRaSH Guides + Gemini Pro analysis)
    fixedPorts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        CRITICAL: Force SABnzbd to use fixed ports instead of dynamic allocation.

        When enabled, SABnzbd will fail to start if its configured port is unavailable,
        rather than silently starting on an alternative port. This is essential for:
        - *arr service integration (they expect SABnzbd on a specific port)
        - Reverse proxy configuration
        - Firewall rules
      '';
    };

    enableHttpsVerification = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        SECURITY CRITICAL: Enable HTTPS certificate verification for outbound connections.

        When enabled, SABnzbd will validate SSL/TLS certificates for update checks,
        RSS feeds, and other external connections.
      '';
    };

    cacheLimit = lib.mkOption {
      type = lib.types.str;
      default = "1G";
      description = ''
        Article cache size limit (RAM allocation).

        This controls how much memory SABnzbd can use for caching downloaded articles
        before writing to disk. Tune based on available system RAM:
        - Systems with 4GB RAM: "512M"
        - Systems with 8GB RAM: "1G"
        - Systems with 16GB+ RAM: "2G" or higher
      '';
      example = "2G";
    };

    bandwidthPercent = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = ''
        Maximum bandwidth usage as percentage of available connection.

        Setting this to 100 will saturate the network link, which can:
        - Increase latency for *arr API calls, causing timeouts
        - Impact other services sharing the connection (Plex, SSH, etc.)

        Recommended: 80-90 for shared servers, 100 for dedicated download servers.
      '';
    };

    queueLimit = lib.mkOption {
      type = lib.types.int;
      default = 20;
      description = ''
        Maximum number of items allowed in download queue.

        The *arr applications can send large batches of downloads during backfills.
        Recommended: 20 for normal use, 50+ for large libraries with frequent backfills.
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ 0 1 2 ];
      default = 1;
      description = ''
        Logging verbosity level.
        - 0 = Error only
        - 1 = Info (recommended)
        - 2 = Debug (troubleshooting)
      '';
    };
  };

  # Service-specific configuration
  extraConfig = cfg: {
    # Note: SOPS templates for API key and Usenet credentials are defined in
    # the host's secrets.nix file (e.g., hosts/forge/secrets.nix)
    # The config generator will read credentials from the environment variables.

    # Config generator script for sabnzbd.ini
    modules.services.sabnzbd.configGenerator.script = ''
            set -eu
            CONFIG_FILE="${cfg.dataDir}/sabnzbd.ini"
            CONFIG_DIR="${cfg.dataDir}"

            # Only generate if config doesn't exist
            if [ ! -f "$CONFIG_FILE" ]; then
              echo "Config missing, generating from Nix settings..."
              mkdir -p "$CONFIG_DIR"

              # Read API key from environment if provided via sops
              API_KEY_SETTING=""
              if [ -n "''${SABNZBD__API_KEY:-}" ]; then
                echo "Injecting API key from sops-nix..."
                API_KEY_SETTING="api_key = $SABNZBD__API_KEY"
              fi

              # Generate declarative config with TRaSH Guides best practices
              cat > "$CONFIG_FILE" << 'EOFCONFIG'
      [misc]
      # === Basic Connection & Path Settings ===
      host = 0.0.0.0
      port = 8080
      download_dir = /data/sab/incomplete
      complete_dir = /data/sab/complete
      permissions = 0775
      # Create files with 664, directories with 775 for *arr service access
      umask = 002

      # === MUST HAVE SETTINGS (TRaSH Guides) ===
      # Security: Whitelist API access to specific hostnames
      host_whitelist = ${lib.concatStringsSep ", " ([ "sabnzbd" "localhost" "127.0.0.1" ] ++ cfg.extraHostWhitelist)}

      # Security: Block potentially malicious file extensions
      unwanted_extensions = .ade, .adp, .app, .asp, .bas, .bat, .cer, .chm, .cmd, .com, .cpl, .crt, .csh, .der, .exe, .fxp, .gadget, .hlp, .hta, .inf, .ins, .isp, .its, .js, .jse, .ksh, .lnk, .mad, .maf, .mag, .mam, .maq, .mar, .mas, .mat, .mau, .mav, .maw, .mda, .mdb, .mde, .mdt, .mdw, .mdz, .msc, .msh, .msh1, .msh2, .msh1xml, .msh2xml, .mshxml, .msi, .msp, .mst, .ops, .pcd, .pif, .plg, .prf, .prg, .pst, .reg, .scf, .scr, .sct, .shb, .shs, .ps1, .ps1xml, .ps2, .ps2xml, .psc1, .psc2, .tmp, .url, .vb, .vbe, .vbs, .vsmacros, .vsw, .ws, .wsc, .wsf, .wsh, .xnk

      # *arr Integration: Unpack directly to final directory to enable hardlinks
      direct_unpack = 1

      # *arr Integration: Disable SABnzbd sorting - let *arrs manage priority
      enable_job_sorting = 0

      # Data Integrity: Only post-process verified downloads
      post_process_only_verified = 1

      # === RECOMMENDED DEFAULTS (TRaSH Guides) ===
      # Performance & Reliability
      allow_dupes = 0
      pause_on_post_processing = 1
      pre_check = 1
      queue_stalled_time = 300
      top_only = 1

      # Convenience
      enable_recursive_unpack = 1
      ignore_samples = 1
      nzb_backup_dir = /config/nzb-backup

      # === CRITICAL OPERATIONAL SETTINGS ===
      # Stability: Force fixed ports to prevent silent port changes on boot
      fixed_ports = ${if cfg.fixedPorts then "1" else "0"}

      # Security: Enable HTTPS certificate verification (MITM protection)
      enable_https_verification = ${if cfg.enableHttpsVerification then "1" else "0"}

      # Performance: Article cache limit (tune based on system RAM)
      cache_limit = ${cfg.cacheLimit}

      # Integration: Bandwidth limit to prevent network saturation
      bandwidth_perc = ${toString cfg.bandwidthPercent}

      # Integration: Maximum queue size for *arr service bulk operations
      queue_limit = ${toString cfg.queueLimit}

      # Operational: Logging verbosity (0=Error, 1=Info, 2=Debug)
      log_level = ${toString cfg.logLevel}

      # Declaratively managed Usenet servers
      [servers]
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (_name: server: ''
      [[${server.host}]]
      name = ${server.host}
      displayname = ${server.host}
      host = ${server.host}
      port = ${toString server.port}
      timeout = 60
      username = __USENET_USERNAME__
      password = __USENET_PASSWORD__
      connections = ${toString server.connections}
      ssl = ${if server.ssl then "1" else "0"}
      ssl_verify = 2
      ssl_ciphers = ""
      enable = 1
      required = 0
      optional = 0
      retention = ${toString server.retention}
      expire_date = ""
      quota = ""
      usage_at_start = 0
      priority = ${toString server.priority}
      '') cfg.usenetProviders)}

      # Pre-configured categories for *arr services
      [categories]
      [[*]]
      name = *
      order = 0
      pp = 3
      script = None
      dir = ""
      priority = 0
      ${lib.concatStringsSep "\n" (lib.imap0 (idx: name:
        let catCfg = cfg.categories.${name}; in ''
      [[${name}]]
      name = ${name}
      order = ${toString (idx + 1)}
      pp = 3
      script = Default
      dir = ${catCfg.dir}
      priority = ${catCfg.priority}
      '') (lib.attrNames cfg.categories))}
      EOFCONFIG

              # Inject API key if provided via sops environment variable
              if [ -n "''${SABNZBD__API_KEY:-}" ]; then
                # Insert api_key under [misc] section (after first line)
                sed -i '2i api_key = '"$SABNZBD__API_KEY" "$CONFIG_FILE"
              fi

              # Inject Usenet credentials if provided via sops environment variables
              if [ -n "''${SABNZBD__USENET__USERNAME:-}" ] && [ -n "''${SABNZBD__USENET__PASSWORD:-}" ]; then
                echo "Injecting Usenet credentials from sops-nix..."
                sed -i "s/__USENET_USERNAME__/$SABNZBD__USENET__USERNAME/g" "$CONFIG_FILE"
                sed -i "s/__USENET_PASSWORD__/$SABNZBD__USENET__PASSWORD/g" "$CONFIG_FILE"
              fi

              chmod 640 "$CONFIG_FILE"
              echo "Configuration generated at $CONFIG_FILE"
            else
              echo "Config exists at $CONFIG_FILE, preserving existing file"
            fi
    '';
  };
}
