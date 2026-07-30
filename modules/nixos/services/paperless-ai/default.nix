# modules/nixos/services/paperless-ai/default.nix
#
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
# Factory-based implementation (see lib/service-factory.nix).
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "paperless-ai";
  description = "Paperless-AI";

  spec = {
    # Core service configuration. The container internally always runs on
    # port 3000; cfg.port is the external mapping.
    port = 3000;
    image = "clusterzx/paperless-ai:3.0.9@sha256:2b65888163fd59716f1c8285b31c5bd0b30c9c3c192c42b516688e3887d4ba60";
    operationalProfile = "productivity";
    displayName = "Paperless-AI";
    function = "document_tagging";

    # Health check: verify web UI is responding (uses upstream /health endpoint)
    healthCommand = "curl -f http://127.0.0.1:3000/health || exit 1";
    startPeriod = "60s";

    # ZFS tuning - optimal for SQLite database
    zfsRecordSize = "16K";

    resources = {
      memory = "256M";
      memoryReservation = "128M";
      cpus = "0.5";
    };

    # Runs as the (shared) paperless user via a numeric --user flag added
    # below - the username does not exist inside the image, so the factory's
    # name-based --user flag cannot be used. The PUID/PGID injection is
    # neutralized in extraConfig.
    runAsRoot = true;

    # Data lives at /app/data plus several writable subdirectory mounts.
    skipDefaultConfigMount = true;
    volumes = cfg: [
      "${cfg.dataDir}:/app/data:rw"
      # Mount SOPS-rendered .env file directly (symlinks don't work in containers)
      "${config.sops.templates."paperless-ai-env".path}:/app/data/.env:ro"
      # Additional writable paths (container expects to write here)
      "${cfg.dataDir}/logs:/app/logs:rw"
      "${cfg.dataDir}/.pm2:/app/.pm2:rw"
      "${cfg.dataDir}/nltk_data:/app/nltk_data:rw"
      "${cfg.dataDir}/openapi:/app/OPENAPI:rw"
      # Only mount images subdir - /app/public contains static CSS/JS assets
      "${cfg.dataDir}/public-images:/app/public/images:rw"
    ];

    extraOptions = { cfg, config, ... }: [
      # Use UID:GID (writable paths redirected to /app/data via env vars)
      "--user=${toString config.users.users.${cfg.user}.uid}:${toString config.users.groups.${cfg.group}.gid}"
    ];
  };

  extraOptions = {
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
      restrictToExisting = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Restrict AI output to tags that already exist in Paperless.
          Unknown model-generated tags are discarded instead of created.
        '';
      };

      managed = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Tags to create idempotently before Paperless-AI starts.";
      };

      pruneUnmanaged = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Delete Paperless tags not present in tags.managed before startup.
          Documents are preserved; only their unmanaged tag associations are removed.
        '';
      };

      reconcileOnCalendar = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional systemd calendar schedule for reconciling managed tags.";
      };

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

    customFields = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          value = lib.mkOption {
            type = lib.types.str;
            description = "Paperless custom field name.";
          };
          data_type = lib.mkOption {
            type = lib.types.enum [
              "string"
              "url"
              "date"
              "boolean"
              "integer"
              "float"
              "monetary"
              "documentlink"
              "select"
              "longtext"
            ];
            default = "string";
            description = "Paperless custom field data type.";
          };
          currency = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Default currency for monetary custom fields.";
          };
        };
      });
      default = [ ];
      description = "Custom fields Paperless-AI may extract and update.";
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

    # Preserve the pre-factory backup defaults.
    backup = lib.mkOption {
      type = lib.types.nullOr mylib.types.backupSubmodule;
      default = {
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

    # Paperless-AI exposes no Prometheus metrics endpoint - keep metrics opt-in.
    metrics = lib.mkOption {
      type = lib.types.nullOr mylib.types.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration (Paperless-AI has no native metrics)";
    };
  };

  extraConfig = cfg: {
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
        assertion = !cfg.tags.pruneUnmanaged || cfg.tags.managed != [ ];
        message = "Paperless-AI tags.pruneUnmanaged requires a non-empty managed tag set.";
      }
      {
        assertion = lib.length cfg.tags.managed == lib.length (lib.unique cfg.tags.managed);
        message = "Paperless-AI tags.managed must not contain duplicates.";
      }
      {
        assertion =
          !cfg.tags.pruneUnmanaged
          || !cfg.scan.addAiProcessedTag
          || lib.elem cfg.scan.aiProcessedTagName cfg.tags.managed;
        message = "Paperless-AI's processed tag must be included in tags.managed when pruning unmanaged tags.";
      }
    ];

    # The service runs as the existing paperless user (created by
    # paperless-ngx); the factory still declares a paperless-ai user entry,
    # which must not pin the registry-less fallback UID.
    users.users.paperless-ai.uid = lib.mkForce null;

    # Pre-factory dataset properties (atime off for the SQLite workload)
    modules.storage.datasets.services.paperless-ai.properties = {
      "com.sun:auto-snapshot" = "true";
      atime = "off";
    };

    # Create subdirectories that are volume-mounted into the container.
    # These must exist before the container starts.
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
    sops.templates."paperless-ai-env" = {
      owner = cfg.user;
      group = cfg.group;
      mode = "0400";
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
        AI_PROVIDER=${if cfg.llm.provider == "anthropic" then "custom" else cfg.llm.provider}
        ${lib.optionalString (cfg.llm.provider == "anthropic" || cfg.llm.baseUrl != null) "CUSTOM_BASE_URL=${if cfg.llm.provider == "anthropic" then "https://api.anthropic.com/v1/" else cfg.llm.baseUrl}"}
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
        RESTRICT_TO_EXISTING_TAGS=${if cfg.tags.restrictToExisting then "yes" else "no"}
        TAGS=${lib.concatStringsSep "," cfg.tags.trigger}
        USE_PROMPT_TAGS=${if cfg.tags.usePromptTags then "yes" else "no"}
        PROMPT_TAGS=${lib.concatStringsSep "," cfg.tags.promptTags}

        # AI Function Limits
        ACTIVATE_TAGGING=${if cfg.aiFunctions.tagging then "yes" else "no"}
        ACTIVATE_CORRESPONDENTS=${if cfg.aiFunctions.correspondents then "yes" else "no"}
        ACTIVATE_DOCUMENT_TYPE=${if cfg.aiFunctions.documentType then "yes" else "no"}
        ACTIVATE_TITLE=${if cfg.aiFunctions.title then "yes" else "no"}
        ACTIVATE_CUSTOM_FIELDS=${if cfg.aiFunctions.customFields then "yes" else "no"}
        CUSTOM_FIELDS=${builtins.toJSON { custom_fields = cfg.customFields; }}

        # System Prompt (newlines escaped for .env format)
        SYSTEM_PROMPT=${lib.replaceStrings ["\n"] ["\\n"] cfg.systemPrompt}

        # API Authentication (for paperless-ai's own API endpoints)
        ${lib.optionalString (cfg.apiKeyFile != null) ''API_KEY=${config.sops.placeholder."paperless-ai/api_key"}''}

        # System Configuration
        TZ=${cfg.timezone}
      '';
    };

    virtualisation.oci-containers.containers.paperless-ai = {
      # Configuration is read from /app/data/.env file; only system-level env
      # vars needed here for path redirects. Replaces the factory's
      # PUID/PGID injection for runAsRoot containers.
      environment = lib.mkForce {
        TZ = cfg.timezone;

        # Writable paths are mounted from dataDir (allows running as non-root)
        # These env vars ensure apps write to mounted locations
        HOME = "/app/data";
        PM2_HOME = "/app/.pm2"; # Mounted from dataDir/.pm2
        NLTK_DATA = "/app/nltk_data"; # Mounted from dataDir/nltk_data
        ANONYMIZED_TELEMETRY = "False";
      };
      # Only bind to localhost - external access goes through the reverse proxy.
      ports = lib.mkForce [
        "127.0.0.1:${toString cfg.port}:3000"
      ];
    };

    systemd.services.paperless-ai-taxonomy = lib.mkIf (cfg.tags.managed != [ ]) {
      description = "Reconcile managed Paperless tags";
      before = [ "${config.virtualisation.oci-containers.backend}-paperless-ai.service" ];
      after = [ "network-online.target" "paperless-web.service" ];
      requires = [ "paperless-web.service" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        LoadCredential = "paperless_token:${cfg.paperless.tokenFile}";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };

      script = ''
        set -euo pipefail

        api_url="${cfg.paperless.apiUrl}/tags/"
        token="$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/paperless_token")"
        tags_file="$(${pkgs.coreutils}/bin/mktemp)"
        trap '${pkgs.coreutils}/bin/rm -f "$tags_file"' EXIT

        fetch_tags() {
          ${pkgs.curl}/bin/curl \
            --fail --silent --show-error \
            --retry 30 --retry-all-errors --retry-delay 2 \
            --header "Authorization: Token $token" \
            "$api_url?page_size=1000" > "$tags_file"
        }

        managed_tags='${builtins.toJSON cfg.tags.managed}'
        fetch_tags

        while IFS= read -r tag_name; do
          if ${pkgs.jq}/bin/jq --exit-status --arg name "$tag_name" \
            '.results[] | select(.name == $name)' "$tags_file" >/dev/null; then
            continue
          fi

          payload="$(${pkgs.jq}/bin/jq --null-input --compact-output --arg name "$tag_name" '{name: $name}')"
          ${pkgs.curl}/bin/curl \
            --fail --silent --show-error \
            --request POST \
            --header "Authorization: Token $token" \
            --header "Content-Type: application/json" \
            --data "$payload" \
            "$api_url" >/dev/null
          echo "Created managed Paperless tag: $tag_name"
        done < <(${pkgs.jq}/bin/jq --raw-output '.[]' <<< "$managed_tags")

        ${lib.optionalString cfg.tags.pruneUnmanaged ''
          fetch_tags
          while IFS= read -r tag; do
            tag_id="$(${pkgs.jq}/bin/jq --raw-output '.id' <<< "$tag")"
            tag_name="$(${pkgs.jq}/bin/jq --raw-output '.name' <<< "$tag")"

            if ${pkgs.jq}/bin/jq --exit-status --arg name "$tag_name" \
              'index($name) != null' <<< "$managed_tags" >/dev/null; then
              continue
            fi

            ${pkgs.curl}/bin/curl \
              --fail --silent --show-error \
              --request DELETE \
              --header "Authorization: Token $token" \
              "$api_url$tag_id/" >/dev/null
            echo "Removed unmanaged Paperless tag: $tag_name"
          done < <(${pkgs.jq}/bin/jq --compact-output '.results[] | {id, name}' "$tags_file")
        ''}
      '';
    };

    systemd.timers.paperless-ai-taxonomy = lib.mkIf
      (cfg.tags.managed != [ ] && cfg.tags.reconcileOnCalendar != null)
      {
        description = "Periodically reconcile managed Paperless tags";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.tags.reconcileOnCalendar;
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };

    # Wait for SOPS to create the .env file
    systemd.services."${config.virtualisation.oci-containers.backend}-paperless-ai" = {
      wants = [ "sops-nix.service" ];
      requires = lib.optional (cfg.tags.managed != [ ]) "paperless-ai-taxonomy.service";
      after = [ "sops-nix.service" ]
        ++ lib.optional (cfg.tags.managed != [ ]) "paperless-ai-taxonomy.service";
    };

    # Preserve the pre-factory notification wording
    modules.notifications.templates."paperless-ai-failure" =
      lib.mkIf (config.modules.notifications.enable or false && cfg.notifications != null && cfg.notifications.enable) {
        body = ''
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
}
