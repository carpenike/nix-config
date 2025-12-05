# Paperless-AI - AI-powered document tagging for Paperless-ngx
# https://github.com/clusterzx/paperless-ai
#
# Design Decision: Container-based implementation
# - No native NixOS module available in nixpkgs
# - Upstream only provides container images
# - Connects to existing Paperless-ngx instance for AI-assisted tagging
#
# Port: 3000 (HTTP)
# Data: /app/data (SQLite database for state tracking)
# Auth: No native OIDC - use caddySecurity for SSO
#
{ lib
, pkgs
, config
, podmanLib
, ...
}:
let
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };

  cfg = config.modules.services.paperless-ai;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;

  serviceName = "paperless-ai";
  paperlessAiPort = cfg.port;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-${serviceName}.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";

  # ZFS replication config discovery (for preseed)
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        replicationInfo = (sanoidDatasets.${dsPath} or { }).replication or null;
        parentPath =
          if lib.elem "/" (lib.stringToCharacters dsPath) then
            lib.removeSuffix "/${lib.last (lib.splitString "/" dsPath)}" dsPath
          else
            "";
      in
      if replicationInfo != null then
        { sourcePath = dsPath; replication = replicationInfo; }
      else
        findReplication parentPath;

  foundReplication = findReplication datasetPath;

  replicationConfig =
    if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then
      null
    else
      let
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        targetDataset =
          if datasetSuffix == "" then
            foundReplication.replication.targetDataset
          else
            "${foundReplication.replication.targetDataset}/${datasetSuffix}";
        sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
        sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
        sendOptions = foundReplication.replication.sendOptions or "w";
        recvOptions = foundReplication.replication.recvOptions or "u";
      };
in
{
  options.modules.services.paperless-ai = {
    enable = lib.mkEnableOption "Paperless-AI document tagging service";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/paperless-ai";
      description = "Path to Paperless-AI data directory (maps to /app/data in container)";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port for Paperless-AI web interface";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "paperless";
      description = ''
        User account under which Paperless-AI runs.
        Defaults to 'paperless' to share permissions with paperless-ngx.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "paperless";
      description = ''
        Group under which Paperless-AI runs.
        Defaults to 'paperless' to share permissions with paperless-ngx.
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "clusterzx/paperless-ai:3.0.9";
      description = ''
        Full container image name including tag.
        Use Renovate bot to automate version updates.
      '';
      example = "clusterzx/paperless-ai:3.0.9@sha256:...";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    # =========================================================================
    # Paperless-ngx Integration
    # =========================================================================
    paperless = {
      apiUrl = lib.mkOption {
        type = lib.types.str;
        description = ''
          Full URL to Paperless-ngx API endpoint.
          Example: "http://localhost:28981/api" or "https://paperless.example.com/api"
        '';
        example = "http://localhost:28981/api";
      };

      tokenFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to file containing the Paperless-ngx API token.
          Generate via Paperless admin: Settings → API Tokens
        '';
        example = "/run/secrets/paperless-ai/paperless_token";
      };

      username = lib.mkOption {
        type = lib.types.str;
        description = ''
          Username of the paperless-ngx account that paperless-ai will use.
          This is the web UI login username, NOT the Linux system user.
          The API token should belong to this user.
        '';
        example = "admin";
      };
    };

    # =========================================================================
    # LLM Configuration
    # =========================================================================
    llm = {
      provider = lib.mkOption {
        type = lib.types.enum [ "openai" "ollama" "anthropic" "custom" ];
        default = "custom";
        description = ''
          AI provider to use. Use "custom" for LiteLLM or other OpenAI-compatible APIs.
        '';
      };

      baseUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Base URL for the LLM API (required for "custom" provider).
          For LiteLLM: "https://llm.holthome.net/v1"
        '';
        example = "https://llm.holthome.net/v1";
      };

      model = lib.mkOption {
        type = lib.types.str;
        default = "gpt-4o";
        description = ''
          Model name to use for document analysis.
          Must be available at the configured API endpoint.
        '';
        example = "gpt-5.1";
      };

      apiKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to file containing the LLM API key.
          Required for all providers except local Ollama.
        '';
        example = "/run/secrets/paperless-ai/llm_api_key";
      };
    };

    # =========================================================================
    # Scanning Configuration
    # =========================================================================
    scan = {
      interval = lib.mkOption {
        type = lib.types.str;
        default = "*/30 * * * *";
        description = ''
          Cron expression for document scanning interval.
          Default: every 30 minutes.
        '';
        example = "0 * * * *"; # Every hour
      };

      addAiProcessedTag = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to add an "AI-Processed" tag to documents after analysis.
          Prevents re-processing of already-analyzed documents.
        '';
      };

      useExistingData = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to use existing tags/correspondents when training the model.
        '';
      };

      processPredefinedDocuments = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to process documents that already have predefined tags.
          When true, scans documents matching the 'tags' list.
        '';
      };

      aiProcessedTagName = lib.mkOption {
        type = lib.types.str;
        default = "ai-processed";
        description = ''
          Name of the tag added to documents after AI processing.
          Used to prevent re-processing of analyzed documents.
        '';
      };
    };

    # =========================================================================
    # Tag Configuration
    # =========================================================================
    tags = {
      trigger = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          List of tags that trigger AI processing.
          If empty, processes all unprocessed documents.
          Use with processPredefinedDocuments = true.
        '';
        example = [ "pre-process" "needs-ai" ];
      };

      usePromptTags = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to use prompt-specific tags.
          Allows different prompts for documents with different tags.
        '';
      };

      promptTags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Tags that trigger custom prompts.
          Only used when usePromptTags = true.
        '';
        example = [ "invoice" "receipt" "contract" ];
      };
    };

    # =========================================================================
    # AI Function Limits
    # =========================================================================
    # These control which AI features are active during document analysis
    aiFunctions = {
      tagging = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable AI to automatically assign relevant tags to documents.";
      };

      correspondents = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable AI to identify document senders/correspondents automatically.";
      };

      documentType = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable AI to determine the type of document automatically (e.g., Invoice, Contract).";
      };

      title = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable AI to generate meaningful titles for documents.";
      };

      customFields = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable AI to extract custom field values from documents.";
      };
    };

    # =========================================================================
    # API Authentication
    # =========================================================================
    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to file containing the API key for paperless-ai's own API.
        This secures the paperless-ai REST endpoints (separate from LLM API key).
        If null, API access may be unauthenticated or use a generated key.
      '';
      example = "/run/secrets/paperless-ai/api_key";
    };

    # =========================================================================
    # Advanced Configuration
    # =========================================================================
    systemPrompt = lib.mkOption {
      type = lib.types.str;
      default = ''
        You are a personalized document analyzer. Your task is to analyze documents and extract relevant information.

        Analyze the document content and extract the following information into a structured JSON object:

        1. title: Create a concise, meaningful title for the document
        2. correspondent: Identify the sender/institution but do not include addresses
        3. tags: Select up to 4 relevant thematic tags
        4. document_date: Extract the document date (format: YYYY-MM-DD)
        5. document_type: Determine a precise type that classifies the document (e.g. Invoice, Contract, Employer, Information and so on)
        6. language: Determine the document language (e.g. "de" or "en")

        Important rules for the analysis:

        For tags:
        - FIRST check the existing tags before suggesting new ones
        - Use only relevant categories
        - Maximum 4 tags per document, less if sufficient (at least 1)
        - Avoid generic or too specific tags
        - Use only the most important information for tag creation
        - The output language is the one used in the document! IMPORTANT!

        For the title:
        - Short and concise, NO ADDRESSES
        - Contains the most important identification features
        - For invoices/orders, mention invoice/order number if available
        - The output language is the one used in the document! IMPORTANT!

        For the correspondent:
        - Identify the sender or institution
          When generating the correspondent, always create the shortest possible form of the company name (e.g. "Amazon" instead of "Amazon EU SARL, German branch")

        For the document date:
        - Extract the date of the document
        - Use the format YYYY-MM-DD
        - If multiple dates are present, use the most relevant one

        For the language:
        - Determine the document language
        - Use language codes like "de" for German or "en" for English
        - If the language is not clear, use "und" as a placeholder
      '';
      description = ''
        System prompt for document analysis.
        The prompt instructs the AI to return a JSON object with:
        - title: Document title
        - correspondent: Sender/institution
        - tags: Array of relevant tags (max 4)
        - document_date: Date in YYYY-MM-DD format
        - document_type: Classification type
        - language: Document language code
      '';
    };

    # =========================================================================
    # Container Configuration
    # =========================================================================
    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "256M";
        memoryReservation = "128M";
        cpus = "0.5";
      };
      description = "Resource limits for the container";
    };

    healthcheck = {
      enable = lib.mkEnableOption "container health check" // { default = true; };
      interval = lib.mkOption {
        type = lib.types.str;
        default = "30s";
        description = "Frequency of health checks.";
      };
      timeout = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Timeout for each health check.";
      };
      retries = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Number of retries before marking as unhealthy.";
      };
      startPeriod = lib.mkOption {
        type = lib.types.str;
        default = "60s";
        description = "Grace period for the container to initialize.";
      };
    };

    # =========================================================================
    # Standardized Submodules
    # =========================================================================
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Paperless-AI web interface";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "documents" "paperless-ai" "config" ];
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/paperless-ai";
        excludePatterns = lib.mkDefault [
          "**/*.log"
        ];
      };
      description = "Backup configuration for Paperless-AI";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "service-alerts" ];
        };
        customMessages = {
          failure = "Paperless-AI service failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Paperless-AI service events";
    };

    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        description = "Restic repository URL for restore operations";
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to Restic password file";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., for B2 credentials)";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = ''
          Order and selection of restore methods to attempt.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # =========================================================================
      # Assertions
      # =========================================================================
      assertions = [
        {
          assertion = cfg.paperless.apiUrl != "";
          message = "Paperless-AI requires paperless.apiUrl to be set.";
        }
        {
          assertion = cfg.llm.provider != "custom" || cfg.llm.baseUrl != null;
          message = "Paperless-AI with 'custom' LLM provider requires llm.baseUrl to be set.";
        }
        {
          assertion = cfg.backup == null || !cfg.backup.enable || cfg.backup.repository != null;
          message = "Paperless-AI backup.enable requires backup.repository to be set.";
        }
        {
          assertion = !cfg.preseed.enable || cfg.preseed.repositoryUrl != "";
          message = "Paperless-AI preseed.enable requires preseed.repositoryUrl to be set.";
        }
      ];

      # =========================================================================
      # Caddy Reverse Proxy Registration
      # =========================================================================
      modules.services.caddy.virtualHosts.${serviceName} = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = paperlessAiPort;
        };
        auth = cfg.reverseProxy.auth;
        caddySecurity = cfg.reverseProxy.caddySecurity;
        security = cfg.reverseProxy.security;
        reverseProxyBlock = cfg.reverseProxy.reverseProxyBlock or "";
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # =========================================================================
      # ZFS Dataset
      # =========================================================================
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for SQLite database
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
          atime = "off";
        };
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # =========================================================================
      # User (uses existing paperless user by default)
      # =========================================================================
      # Note: User/group typically already exist from paperless-ngx
      # Only create if using a different user
      users.users.${cfg.user} = lib.mkIf (cfg.user != "paperless") {
        isSystemUser = true;
        group = cfg.group;
        description = "Paperless-AI service user";
      };

      users.groups.${cfg.group} = lib.mkIf (cfg.group != "paperless") { };

      # =========================================================================
      # Tmpfiles Rules for Writable Subdirectories
      # =========================================================================
      # Create subdirectories that are volume-mounted into the container
      # These must exist before the container starts
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir}/logs 0750 ${cfg.user} ${cfg.group} -"
        "d ${cfg.dataDir}/.pm2 0750 ${cfg.user} ${cfg.group} -"
        "d ${cfg.dataDir}/nltk_data 0750 ${cfg.user} ${cfg.group} -"
        "d ${cfg.dataDir}/openapi 0750 ${cfg.user} ${cfg.group} -"
        # Only mount images subdir - /app/public contains static assets we must not overwrite
        "d ${cfg.dataDir}/public-images 0750 ${cfg.user} ${cfg.group} -"
      ];

      # =========================================================================
      # SOPS Template for .env Configuration File
      # =========================================================================
      # paperless-ai reads configuration from /app/data/.env file, not from
      # environment variables. We mount this file directly into the container.
      sops.templates."${serviceName}-env" = {
        owner = "root";
        group = "root";
        mode = "0444"; # Readable by container user
        content = ''
          # Initial Setup - always 'no' since .env is read-only (managed by NixOS/SOPS)
          # All configuration must be done via NixOS module options
          PAPERLESS_AI_INITIAL_SETUP=no

          # Paperless-ngx Integration
          PAPERLESS_API_URL=${cfg.paperless.apiUrl}
          PAPERLESS_API_TOKEN=${config.sops.placeholder."paperless-ai/paperless_token"}
          PAPERLESS_USERNAME=${cfg.paperless.username}
          # Python RAG service uses different env var names
          PAPERLESS_URL=${cfg.paperless.apiUrl}

          # LLM Configuration
          AI_PROVIDER=${cfg.llm.provider}
          ${lib.optionalString (cfg.llm.baseUrl != null) "CUSTOM_BASE_URL=${cfg.llm.baseUrl}"}
          CUSTOM_MODEL=${cfg.llm.model}
          ${lib.optionalString (cfg.llm.apiKeyFile != null) "CUSTOM_API_KEY=${config.sops.placeholder."paperless-ai/llm_api_key"}"}
          # Some backends also check these env vars
          OPENAI_API_KEY=
          OPENAI_MODEL=

          # Scanning Configuration
          SCAN_INTERVAL=${cfg.scan.interval}
          ADD_AI_PROCESSED_TAG=${if cfg.scan.addAiProcessedTag then "yes" else "no"}
          AI_PROCESSED_TAG_NAME=${cfg.scan.aiProcessedTagName}
          USE_EXISTING_DATA=${if cfg.scan.useExistingData then "yes" else "no"}
          PROCESS_PREDEFINED_DOCUMENTS=${if cfg.scan.processPredefinedDocuments then "yes" else "no"}

          # Tag Configuration
          TAGS=${lib.concatStringsSep "," cfg.tags.trigger}
          USE_PROMPT_TAGS=${if cfg.tags.usePromptTags then "yes" else "no"}
          PROMPT_TAGS=${lib.concatStringsSep "," cfg.tags.promptTags}

          # AI Function Limits
          ACTIVATE_TAGGING=${if cfg.aiFunctions.tagging then "yes" else "no"}
          ACTIVATE_CORRESPONDENTS=${if cfg.aiFunctions.correspondents then "yes" else "no"}
          ACTIVATE_DOCUMENT_TYPE=${if cfg.aiFunctions.documentType then "yes" else "no"}
          ACTIVATE_TITLE=${if cfg.aiFunctions.title then "yes" else "no"}
          ACTIVATE_CUSTOM_FIELDS=${if cfg.aiFunctions.customFields then "yes" else "no"}

          # System Prompt (newlines escaped for .env format)
          SYSTEM_PROMPT=${lib.replaceStrings ["\n"] ["\\n"] cfg.systemPrompt}

          # API Authentication (for paperless-ai's own API endpoints)
          ${lib.optionalString (cfg.apiKeyFile != null) ''API_KEY=${config.sops.placeholder."paperless-ai/api_key"}''}

          # System Configuration
          TZ=${cfg.timezone}
        '';
      };

      # =========================================================================
      # Container Configuration
      # =========================================================================
      virtualisation.oci-containers.containers.${serviceName} = podmanLib.mkContainer serviceName {
        image = cfg.image;
        # Configuration is read from /app/data/.env file
        # Only system-level env vars needed here for path redirects
        environment = {
          TZ = cfg.timezone;

          # Writable paths are mounted from dataDir (allows running as non-root)
          # These env vars ensure apps write to mounted locations
          HOME = "/app/data";
          PM2_HOME = "/app/.pm2"; # Mounted from ${dataDir}/.pm2
          NLTK_DATA = "/app/nltk_data"; # Mounted from ${dataDir}/nltk_data
        };

        volumes = [
          "${cfg.dataDir}:/app/data:rw"
          # Mount SOPS-rendered .env file directly (symlinks don't work in containers)
          "${config.sops.templates."${serviceName}-env".path}:/app/data/.env:ro"
          # Additional writable paths (container expects to write here)
          "${cfg.dataDir}/logs:/app/logs:rw"
          "${cfg.dataDir}/.pm2:/app/.pm2:rw"
          "${cfg.dataDir}/nltk_data:/app/nltk_data:rw"
          "${cfg.dataDir}/openapi:/app/OPENAPI:rw"
          # Only mount images subdir - /app/public contains static CSS/JS assets
          "${cfg.dataDir}/public-images:/app/public/images:rw"
        ];

        ports = [
          "127.0.0.1:${toString paperlessAiPort}:3000"
        ];

        resources = cfg.resources;

        extraOptions = [
          "--pull=newer"
          # Use UID:GID (writable paths redirected to /app/data via env vars)
          "--user=${toString config.users.users.${cfg.user}.uid}:${toString config.users.groups.${cfg.group}.gid}"
        ] ++ lib.optionals cfg.healthcheck.enable [
          # Health check: verify web UI is responding
          ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:3000/)" = 200 ]' ''
          "--health-interval=0s"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
        ];
      };

      # =========================================================================
      # Systemd Service Configuration
      # =========================================================================
      systemd.services."${config.virtualisation.oci-containers.backend}-${serviceName}" = lib.mkMerge [
        # Core dependencies - wait for SOPS to create .env file
        {
          wants = [ "sops-nix.service" ];
          after = [ "sops-nix.service" ];
        }
        # Failure notifications
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@${serviceName}-failure:%n.service" ];
        })
        # Preseed dependency
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-${serviceName}.service" ];
          after = [ "preseed-${serviceName}.service" ];
        })
      ];

      # =========================================================================
      # Notification Template
      # =========================================================================
      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "${serviceName}-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Paperless-AI</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The Paperless-AI document tagging service has entered a failed state.

            <b>Quick Actions:</b>
            1. Check logs:
               <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
            2. Restart service:
               <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
          '';
        };
      };
    })

    # =========================================================================
    # Preseed Service
    # =========================================================================
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        inherit serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
