# modules/nixos/services/litellm/default.nix
#
# LiteLLM — one Anthropic/OpenAI-compatible front door for every model
# provider forge can reach (Azure Foundry, Anthropic, Gemini, OpenAI, and
# the local copilot-api proxy). Virtual keys, per-key budgets and spend
# tracking live in PostgreSQL; the Admin UI signs in through PocketID.
#
# Factory-based implementation (see lib/service-factory.nix, ADR-011).
# Rebuilt 2026-09-04 from the hand-rolled 2025-12 module; the factory now
# owns the container, dataset, user, Caddy vhost, backup, preseed and
# notifications, and this file keeps only what is LiteLLM-specific.
#
# Image: ghcr.io/berriai/litellm (pinned release tag + digest). The
# `litellm-database` image this module used to default to is now a legacy
# alias — upstream bundles the Prisma toolchain in the main image and says
# new deployments should use it.
#
# Configuration model
# -------------------
# config.yaml is rendered at build time from `models`, `routerSettings`,
# `litellmSettings` and `generalSettings` and mounted read-only from the
# Nix store. It contains NO secrets: every credential is an `os.environ/VAR`
# reference, which LiteLLM resolves from the container environment — the
# documented mechanism, and the reason the old envsubst-at-runtime
# generator is gone. The environment itself is assembled by a root oneshot
# (`litellm-env`) from systemd credentials into /run/litellm/env, so sops
# secrets are never mounted into the container:
#
#   DATABASE_URL          from database.* + the db password credential
#   LITELLM_MASTER_KEY    masterKeyFile, or generated once into
#                         <dataDir>/secrets/master-key
#   LITELLM_SALT_KEY      saltKeyFile, or generated once into
#                         <dataDir>/secrets/salt-key. Encrypts credentials
#                         LiteLLM stores in the database; it can never be
#                         rotated afterwards, so it is persisted on the
#                         (snapshotted, replicated, backed-up) dataset.
#   LITELLM_MODE=PRODUCTION
#   GENERIC_* / PROXY_*   Admin UI SSO (sso.adminUi)
#   <VAR>=<file contents> for every extraCredentialFiles entry
#   + the whole `environmentFile` (provider API keys), verbatim
#
# Production settings that are not the upstream defaults are applied in the
# option defaults below (request_timeout, json_logs, batched spend writes,
# error-log suppression, connection-pool cap) and can be overridden per host.
#
# Exposure
# --------
# Loopback publish only; LAN access through Caddy at reverseProxy.hostName
# (no caddySecurity — LiteLLM enforces its own virtual keys on every API
# route and the UI has its own SSO login). Never in the Cloudflare tunnel.
# Other containers on the same Podman network reach it as `litellm:4000`.
#
# Reference: https://docs.litellm.ai/docs/proxy/prod
# SSO:       https://docs.litellm.ai/docs/proxy/admin_ui_sso
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

let
  inherit (lib) mkOption mkEnableOption types optional optionalAttrs optionalString;

  serviceName = "litellm";
  containerPort = 4000;
  backend = config.virtualisation.oci-containers.backend;
  mainServiceName = "${backend}-${serviceName}";
  mainServiceUnit = "${mainServiceName}.service";
  envUnitName = "${serviceName}-env";

  envDir = "/run/${serviceName}";
  envFile = "${envDir}/env";
  secretsDirOn = cfg: "${cfg.dataDir}/secrets";

  yamlFormat = pkgs.formats.yaml { };

  mkModel = m:
    {
      model_name = m.name;
      litellm_params =
        { model = m.model; }
        // optionalAttrs (m.apiBase != null) { api_base = m.apiBase; }
        // optionalAttrs (m.apiKey != null) { api_key = "os.environ/${m.apiKey}"; }
        // optionalAttrs (m.apiVersion != null) { api_version = m.apiVersion; }
        // m.extraParams;
    }
    // optionalAttrs (m.modelInfo != { }) { model_info = m.modelInfo; };

  renderConfig = cfg: yamlFormat.generate "litellm-config.yaml" {
    model_list = map mkModel cfg.models;
    router_settings = cfg.routerSettings;
    litellm_settings = cfg.litellmSettings;
    general_settings =
      { master_key = "os.environ/LITELLM_MASTER_KEY"; }
      // optionalAttrs cfg.sso.adminUi.enable { ui_access_mode = "all"; }
      // cfg.generalSettings;
  };

  modelSubmodule = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Model name clients request. Wildcards such as `anthropic/*` are allowed.";
        example = "claude-sonnet";
      };
      model = mkOption {
        type = types.str;
        description = "Provider-qualified model identifier (LiteLLM `litellm_params.model`).";
        example = "anthropic/claude-sonnet-5";
      };
      apiBase = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Provider base URL (Azure resources, self-hosted proxies).";
        example = "http://copilot-api:4141";
      };
      apiKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Name of the environment variable holding the API key. Rendered as
          `os.environ/<NAME>`; the variable must be present in
          `environmentFile` or `extraCredentialFiles`.
        '';
        example = "AZURE_API_KEY";
      };
      apiVersion = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Provider API version (Azure).";
        example = "2024-12-01-preview";
      };
      extraParams = mkOption {
        type = types.attrsOf types.anything;
        default = { };
        description = "Additional `litellm_params` for this deployment.";
        example = { rpm = 100; };
      };
      modelInfo = mkOption {
        type = types.attrsOf types.anything;
        default = { };
        description = "`model_info` block (e.g. `mode = \"embedding\"`).";
        example = { mode = "embedding"; };
      };
    };
  };
in
mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = serviceName;
  description = "LiteLLM AI gateway";

  spec = {
    port = containerPort;
    inherit containerPort;
    image = "ghcr.io/berriai/litellm:v1.99.1@sha256:a53a7d3ffebede1925bd3ee8a21e4a7b9b63e2e68ec883af136edcccb6eeb82c";
    operationalProfile = "ai";
    displayName = "LiteLLM";
    function = "ai_gateway";

    # /health needs a key; /health/liveliness does not. The image ships
    # wget, not curl (matches upstream docker-compose).
    healthCommand = "wget --no-verbose --tries=1 --spider http://127.0.0.1:${toString containerPort}/health/liveliness || exit 1";
    # Prisma migrations run on every start and can take a while.
    startPeriod = "120s";

    # ~470MB average, 660MB peak observed over 48h on the old deployment;
    # upstream calls 4Gi a floor for high-traffic pods, which this is not.
    resources = {
      memory = "1G";
      memoryReservation = "512M";
      cpus = "1.0";
    };

    # The stock image expects root (Prisma writes into its own tree at
    # startup); the non_root variant would need a different layout.
    runAsRoot = true;

    # config.yaml comes from the store; /app/data is the only writable mount.
    skipDefaultConfigMount = true;
    volumes = cfg: [
      "${renderConfig cfg}:/app/config.yaml:ro"
      "${cfg.dataDir}/data:/app/data:rw"
    ];

    extraOptions = { cfg, ... }:
      lib.mapAttrsToList (host: ip: "--add-host=${host}:${ip}") cfg.extraHosts;
  };

  extraOptions = {
    models = mkOption {
      type = types.listOf modelSubmodule;
      default = [ ];
      description = "Deployments rendered into `model_list`.";
    };

    routerSettings = mkOption {
      type = types.attrsOf types.anything;
      default = {
        routing_strategy = "simple-shuffle";
        num_retries = 2;
        # Long streamed completions with large thinking budgets.
        timeout = 600;
      };
      description = "`router_settings` block.";
    };

    litellmSettings = mkOption {
      type = types.attrsOf types.anything;
      default = {
        drop_params = true;
        set_verbose = false;
        json_logs = true;
        # Upstream default is 6000s; fail hung requests instead.
        request_timeout = 600;
      };
      description = "`litellm_settings` block.";
    };

    generalSettings = mkOption {
      type = types.attrsOf types.anything;
      default = {
        # Batch spend writes instead of one DB write per request.
        proxy_batch_write_at = 60;
        # Provider errors otherwise bloat the spend-logs table.
        disable_error_logs = true;
        database_connection_pool_limit = 10;
      };
      description = ''
        `general_settings` block. `master_key` (and `ui_access_mode` when
        Admin UI SSO is on) are always added; `database_url` is supplied via
        the DATABASE_URL environment variable instead.
      '';
    };

    database = {
      host = mkOption {
        type = types.str;
        default = "host.containers.internal";
        description = "PostgreSQL host as seen from inside the container.";
      };
      port = mkOption {
        type = types.port;
        default = 5432;
        description = "PostgreSQL port.";
      };
      name = mkOption {
        type = types.str;
        default = "litellm";
        description = "Database name.";
      };
      user = mkOption {
        type = types.str;
        default = "litellm";
        description = "Database role.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File containing the database password (sops secret).";
      };
      manageDatabase = mkOption {
        type = types.bool;
        default = true;
        description = "Provision the database and role through modules.services.postgresql.";
      };
      localInstance = mkOption {
        type = types.bool;
        default = true;
        description = "Order the container after the local postgresql.service.";
      };
    };

    masterKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        File containing LITELLM_MASTER_KEY (must start with `sk-`). When
        null a key is generated once into <dataDir>/secrets/master-key.
      '';
    };

    saltKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        File containing LITELLM_SALT_KEY, which encrypts credentials stored
        in the database (`store_model_in_db`). When null a key is generated
        once into <dataDir>/secrets/salt-key. Upstream: the salt key cannot
        be rotated once models are stored, so switching an existing
        deployment from the generated key to a sops one means clearing the
        DB-stored model rows (or the database) first.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Env-file with provider API keys (AZURE_API_KEY=...), appended verbatim to the container environment.";
      example = "/run/secrets/litellm/provider-keys";
    };

    extraCredentialFiles = mkOption {
      type = types.attrsOf types.path;
      default = { };
      description = ''
        Environment variable name → file whose first line becomes that
        variable. Loaded through systemd credentials, so the files may be
        root-only. Used to hand LiteLLM keys owned by other services.
      '';
      example = { COPILOT_API_KEY = "/var/lib/copilot-api/api-key"; };
    };

    extraHosts = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra /etc/hosts entries for the container (hairpin-NAT workaround for id.holthome.net).";
      example = { "id.holthome.net" = "10.89.0.1"; };
    };

    sso.adminUi = {
      enable = mkEnableOption "Admin UI SSO through a generic OIDC provider (free for up to 5 users)";
      clientId = mkOption { type = types.str; default = "litellm"; description = "OIDC client ID."; };
      clientSecretFile = mkOption { type = types.nullOr types.path; default = null; description = "OIDC client secret file."; };
      authorizationEndpoint = mkOption { type = types.str; default = ""; description = "OIDC authorization endpoint."; };
      tokenEndpoint = mkOption { type = types.str; default = ""; description = "OIDC token endpoint."; };
      userinfoEndpoint = mkOption { type = types.str; default = ""; description = "OIDC userinfo endpoint."; };
      scope = mkOption { type = types.str; default = "openid profile email"; description = "OIDC scopes."; };
      redirectUri = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Callback URL registered with the IdP (`https://<host>/sso/callback`). Sets PROXY_BASE_URL.";
      };
      userIdAttribute = mkOption { type = types.str; default = "sub"; description = "Claim used as the LiteLLM user id."; };
      userEmailAttribute = mkOption { type = types.str; default = "email"; description = "Claim used as the email."; };
      userDisplayNameAttribute = mkOption { type = types.str; default = "name"; description = "Claim used as the display name."; };
      userRoleAttribute = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Claim carrying the LiteLLM role. Leave null and use proxyAdminId (see docs/workarounds.md, generic SSO role bug).";
      };
      proxyAdminId = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "User id (per userIdAttribute) granted proxy_admin on SSO login.";
      };
    };

    # /metrics requires a LiteLLM key since v1.85; the factory scraper
    # cannot present one, so keep metrics opt-in.
    metrics = mkOption {
      type = types.nullOr mylib.types.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection (LiteLLM's /metrics is key-authenticated).";
    };
  };

  extraConfig = cfg:
    let
      ui = cfg.sso.adminUi;
      credName = var: "extra-${lib.toLower (lib.replaceStrings [ "_" ] [ "-" ] var)}";
      envScript = ''
        set -euo pipefail
        umask 077
        install -d -o root -g root -m 0700 "${secretsDirOn cfg}"
        tmp="${envFile}.tmp"
        trap 'rm -f "$tmp"' EXIT

        # First line of a credential, newline stripped (key files may
        # carry several keys; the first is ours).
        read_cred() { ${pkgs.coreutils}/bin/head -n 1 "$CREDENTIALS_DIRECTORY/$1" | ${pkgs.coreutils}/bin/tr -d '\n'; }

        # DATABASE_URL — the password is percent-encoded so any character
        # in the secret survives URL parsing.
        db_pass=$(read_cred db-password | ${pkgs.jq}/bin/jq -Rr @uri)
        database_url="postgresql://${cfg.database.user}:$db_pass@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}"

        ${if cfg.masterKeyFile != null then ''
          master_key=$(read_cred master-key)
        '' else ''
          master_key_file="${secretsDirOn cfg}/master-key"
          if [ ! -s "$master_key_file" ]; then
            printf 'sk-%s\n' "$(${pkgs.coreutils}/bin/head -c 48 /dev/urandom | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '/+=\n' | ${pkgs.coreutils}/bin/head -c 48)" > "$master_key_file"
            echo "litellm: generated master key at $master_key_file"
          fi
          master_key=$(${pkgs.coreutils}/bin/tr -d '\n' < "$master_key_file")
        ''}

        ${if cfg.saltKeyFile != null then ''

          salt_key=$(read_cred salt-key)

        '' else ''

          salt_key_file="${secretsDirOn cfg}/salt-key"

          if [ ! -s "$salt_key_file" ]; then

            printf 'sk-%s\n' "$(${pkgs.coreutils}/bin/head -c 48 /dev/urandom | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '/+=\n' | ${pkgs.coreutils}/bin/head -c 48)" > "$salt_key_file"

            echo "litellm: generated salt key at $salt_key_file"

          fi

          salt_key=$(${pkgs.coreutils}/bin/tr -d '\n' < "$salt_key_file")

        ''}


        {
          echo "DATABASE_URL=$database_url"
          echo "LITELLM_MASTER_KEY=$master_key"
          echo "LITELLM_MODE=PRODUCTION"
          echo "LITELLM_SALT_KEY=$salt_key"
          ${optionalString ui.enable ''
            echo "GENERIC_CLIENT_ID=${ui.clientId}"
            echo "GENERIC_CLIENT_SECRET=$(read_cred oidc-client-secret)"
            echo "GENERIC_AUTHORIZATION_ENDPOINT=${ui.authorizationEndpoint}"
            echo "GENERIC_TOKEN_ENDPOINT=${ui.tokenEndpoint}"
            echo "GENERIC_USERINFO_ENDPOINT=${ui.userinfoEndpoint}"
            echo "GENERIC_SCOPE=${ui.scope}"
            ${optionalString (ui.redirectUri != null) ''echo "PROXY_BASE_URL=${lib.removeSuffix "/sso/callback" ui.redirectUri}"''}
            ${optionalString (ui.userIdAttribute != "sub") ''echo "GENERIC_USER_ID_ATTRIBUTE=${ui.userIdAttribute}"''}
            ${optionalString (ui.userEmailAttribute != "email") ''echo "GENERIC_USER_EMAIL_ATTRIBUTE=${ui.userEmailAttribute}"''}
            ${optionalString (ui.userDisplayNameAttribute != "name") ''echo "GENERIC_USER_DISPLAY_NAME_ATTRIBUTE=${ui.userDisplayNameAttribute}"''}
            ${optionalString (ui.userRoleAttribute != null) ''echo "GENERIC_USER_ROLE_ATTRIBUTE=${ui.userRoleAttribute}"''}
            ${optionalString (ui.proxyAdminId != null && ui.userRoleAttribute == null) ''echo "PROXY_ADMIN_ID=${ui.proxyAdminId}"''}
          ''}
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (var: _: ''echo "${var}=$(read_cred ${credName var})"'') cfg.extraCredentialFiles)}
          ${optionalString (cfg.environmentFile != null) ''cat "$CREDENTIALS_DIRECTORY/provider-keys"''}
        } > "$tmp"

        install -m 0600 "$tmp" "${envFile}"
      '';
    in
    {
      assertions = [
        {
          assertion = cfg.database.passwordFile != null;
          message = "modules.services.litellm.database.passwordFile must be set.";
        }
        {
          assertion = !ui.enable || ui.clientSecretFile != null;
          message = "modules.services.litellm.sso.adminUi.clientSecretFile must be set when Admin UI SSO is enabled.";
        }
        {
          assertion = !ui.enable || (ui.authorizationEndpoint != "" && ui.tokenEndpoint != "" && ui.userinfoEndpoint != "");
          message = "modules.services.litellm.sso.adminUi.{authorizationEndpoint,tokenEndpoint,userinfoEndpoint} must all be set when Admin UI SSO is enabled.";
        }
      ];

      modules.services.postgresql.databases.${cfg.database.name} = lib.mkIf cfg.database.manageDatabase {
        owner = cfg.database.user;
        ownerPasswordFile = cfg.database.passwordFile;
        permissionsPolicy = "owner-readwrite+readonly-select";
      };

      virtualisation.oci-containers.containers.${serviceName} = {
        # The image CMD does not pass --config; be explicit.
        cmd = [ "--config" "/app/config.yaml" "--port" (toString containerPort) ];
        environmentFiles = [ envFile ];
        # Drop the PUID/PGID/UMASK the factory injects for runAsRoot images;
        # LiteLLM does not use them.
        environment = lib.mkForce {
          TZ = cfg.timezone;
          LITELLM_CONFIG_PATH = "/app/config.yaml";
        };
        # Loopback only — the factory default publishes on all interfaces.
        ports = lib.mkForce [
          "127.0.0.1:${toString cfg.port}:${toString containerPort}"
        ];
      };

      systemd.services.${mainServiceName} = {
        after = [ "network-online.target" "${envUnitName}.service" ]
          ++ optional cfg.database.localInstance "postgresql.service"
          ++ optional (cfg.database.manageDatabase && cfg.database.localInstance) "postgresql-provision-databases.service";
        wants = [ "network-online.target" ];
        requires = [ "${envUnitName}.service" ]
          ++ optional (cfg.database.manageDatabase && cfg.database.localInstance) "postgresql-provision-databases.service";
        serviceConfig = {
          Restart = lib.mkForce "on-failure";
          RestartSec = "10s";
        };
        preStart = ''
          install -d -o root -g root -m 0750 ${cfg.dataDir}/data
        '';
      };

      # Assembles /run/litellm/env from systemd credentials. PartOf ties its
      # lifetime to the container so a restart re-reads rotated secrets.
      systemd.services.${envUnitName} = {
        description = "LiteLLM environment file generator";
        wantedBy = [ "multi-user.target" ];
        before = [ mainServiceUnit ];
        requiredBy = [ mainServiceUnit ];
        partOf = [ mainServiceUnit ];
        # Writes generated keys into <dataDir>/secrets, so the dataset must be
        # mounted (and restored) first — see the copilot-api-keys note.
        after = [ "zfs-service-datasets.service" "preseed-${serviceName}.service" ];
        requires = [ "zfs-service-datasets.service" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = serviceName;
          RuntimeDirectoryMode = "0700";
          # Keep /run/litellm across a stop of this oneshot. During a switch
          # systemd stops it (PartOf the container) and the container's restart
          # job can run before the start job rewrites the env file; without
          # this the first attempt fails with "open /run/litellm/env: no such
          # file" and only the on-failure restart recovers it (2026-09-04).
          RuntimeDirectoryPreserve = "yes";
          LoadCredential =
            [ "db-password:${cfg.database.passwordFile}" ]
            ++ optional (cfg.environmentFile != null) "provider-keys:${cfg.environmentFile}"
            ++ optional (cfg.masterKeyFile != null) "master-key:${cfg.masterKeyFile}"
            ++ optional (cfg.saltKeyFile != null) "salt-key:${cfg.saltKeyFile}"
            ++ optional (ui.enable && ui.clientSecretFile != null) "oidc-client-secret:${ui.clientSecretFile}"
            ++ lib.mapAttrsToList (var: file: "${credName var}:${file}") cfg.extraCredentialFiles;
        };

        script = envScript;
        # Re-run on the next switch whenever the assembled script changes
        # (RemainAfterExit oneshots are otherwise left as-is, issue #852).
        restartTriggers = [ envScript ];
      };
    };
}
