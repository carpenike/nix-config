agent: ask
description: Scaffold a new NixOS service module with storage, backup, and monitoring integrations
version: 2.10
last_updated: 2025-12-05
changelog: "v2.10: Added Trusted Header Auth pattern (auth proxy) for multi-user apps that accept Remote-User/X-Email headers from proxy (grafana, organizr). Reorganized auth patterns with 6 tiers. Added research checklist for proxy auth support. v2.9: Revised auth priority - prefer disabling native auth + caddySecurity for single-user apps over per-app auth. Native OIDC now only recommended when multi-user authorization matters (user X can do Y). Added Pattern 2 for disable-auth+caddySecurity workflow. Updated decision matrix and examples. v2.8: Added mandatory OIDC/native auth research to Step 0 - always prefer native OIDC over proxy auth. Added hybrid auth pattern (PocketID SSO + API key injection) for services like paperless-ai. Clarified auth decision matrix with priority order. v2.7: Added OIDC/PocketID integration patterns with examples from paperless/mealie/autobrr. Added mylib.monitoring-helpers library documentation for complex alerts. Added healthcheck.enable pattern for container services. Added nfsMountDependency pattern for media services needing NAS access. Added Gatus alert configuration (pushover, thresholds). Expanded forgeDefaults.mkBackupWithTags and backupTags documentation. v2.6: Added mandatory NixOS MCP server research step to check for native packages/modules in both unstable and stable branches BEFORE any other work. Added pkgs.unstable pattern documentation for using newer package versions. Added default Homepage and Gatus contribution requirements for services with web endpoints. v2.5: Added container image pinning with SHA256 digest requirement, GHCR registry preference over Docker Hub, port conflict scanning step, and explicit guidance against :latest tags."
---
# NixOS Service Module Scaffold

## Scope
Use this prompt for: **NEW service modules** requiring full integration (storage, backup, monitoring)

Don't use for: typo fixes, small updates, infrastructure changes, or emergencies.
If unclear, ask clarifying questions BEFORE starting.

## Role
Senior NixOS infrastructure engineer in `nix-config` repo. You understand:
- forge host three-tier architecture
- Contribution pattern (co-located assets)
- ZFS persistence with modules.storage.datasets
- Taskfile-based workflows
- SOPS secret management

---

## MANDATORY: Package Research Phase

**YOU MUST complete this phase FIRST, BEFORE studying patterns or asking questions.**

### Step 0: Search for Native NixOS Package and Module (REQUIRED)

**CRITICAL**: Before assuming a service needs a container, use the NixOS MCP server to search for:
1. Native package availability (in both **unstable** and **stable** branches)
2. Native NixOS service module (e.g., `services.<servicename>`)

**Search both channels:**
```bash
# Use the mcp_nixos_nixos_search tool for package discovery
# Search unstable channel (preferred - more up-to-date packages)
mcp_nixos_nixos_search(query="<servicename>", search_type="packages", channel="unstable")

# Search stable channel for comparison
mcp_nixos_nixos_search(query="<servicename>", search_type="packages", channel="stable")

# Search for NixOS options (service modules)
mcp_nixos_nixos_search(query="services.<servicename>", search_type="options", channel="unstable")
mcp_nixos_nixos_search(query="services.<servicename>", search_type="options", channel="stable")
```

**If native package/module exists:**
- Document package name and available versions in both channels
- If unstable has newer version needed, use `pkgs.unstable.<package>`
- Prefer wrapping native NixOS module over creating container
- Study the native module options with `mcp_nixos_nixos_info`

**The `pkgs.unstable` Pattern:**

This repo makes unstable nixpkgs available via overlay at `pkgs.unstable`:

```nix
# In overlays/default.nix:
unstable-packages = final: _prev: {
  unstable = import inputs.nixpkgs-unstable {
    inherit (final) system;
    config.allowUnfree = true;
  };
};
```

**When to use `pkgs.unstable`:**
- Service package is significantly newer in unstable (security fixes, features)
- Stable version has known bugs fixed in unstable
- Service requires a version only available in unstable

**Usage patterns from existing services:**
```nix
# Direct reference (simple):
package = pkgs.unstable.open-webui;
package = pkgs.unstable.zigbee2mqtt;
package = pkgs.unstable.pocket-id;

# Variable binding (when used multiple times):
let
  unstablePkgs = pkgs.unstable;
in
{
  package = unstablePkgs.home-assistant;
  extraComponents = with unstablePkgs; [ ... ];
}
```

**Document your findings:**
```
NIXOS PACKAGE RESEARCH:
- Package name: <name>
- Stable version: <version> (nixos-24.11)
- Unstable version: <version> (nixos-unstable)
- Native service module: services.<name>.enable (Y/N)
- Decision: [Native module | pkgs.unstable | Container]
- Reasoning: [why this choice]

AUTHENTICATION RESEARCH:
- Native OIDC/OAuth2 support: [Y/N/Unknown]
- Trusted header auth (auth proxy): [Y/N] - accepts Remote-User, X-Email, etc.
- Built-in auth can be disabled: [Y/N] - if Y, prefer caddySecurity for single-user
- Multi-user authorization needed: [Y/N] - user X can do Y (folders, permissions, etc.)
- API key support: [Y/N] - for hybrid auth if native can't be disabled
- Auth decision: [Native OIDC | Trusted Header | Disable+caddySecurity | Hybrid | Built-in | None]
- Reasoning: [why]
```

**If NO native package exists:**
- Check if upstream provides a NixOS flake
- Consider if packaging is feasible
- Only then fall back to container approach

---

## MANDATORY: Pattern Discovery Phase

**YOU MUST complete this phase BEFORE asking the user ANY questions.**

### Step 1: Study Existing Service Modules

**Service Complexity Tiers:**
- **Simple**: dispatcharr (basic service, minimal integration)
- **Moderate**: sonarr, radarr (media services, standard integrations)
- **Complex**: teslamate (database, MQTT, Grafana, multi-service integration hub)

**Start with the service closest in complexity to your target.**

Read complete files based on service complexity:

```bash
# ALWAYS read these baseline examples
cat hosts/_modules/nixos/services/sonarr/default.nix
cat hosts/_modules/nixos/services/radarr/default.nix
cat hosts/_modules/nixos/services/dispatcharr/default.nix

# IF service needs database/MQTT/Grafana integration:
cat hosts/_modules/nixos/services/teslamate/default.nix

# IF service is container-based:
cat hosts/_modules/nixos/services/scrypted/default.nix
cat hosts/_modules/nixos/services/teslamate/default.nix

# Read host integrations
cat hosts/forge/services/sonarr.nix
cat hosts/forge/services/radarr.nix
cat hosts/forge/services/teslamate.nix  # If complex integrations needed

# Discover storage patterns
rg "modules.storage.datasets" --type nix -A 8

# Discover backup patterns
rg "backup.paths" --type nix -A 3
rg "backup.enable" --type nix -A 2
rg "mkBackupWithTags" --type nix -A 2  # Tagged backups with ZFS snapshots

# Discover monitoring patterns
rg "metrics.enable" --type nix -A 3
rg "monitoring-helpers" --type nix -A 3  # Complex alert helpers
cat lib/monitoring-helpers.nix  # Alert template library

# Discover OIDC/PocketID patterns (for services needing SSO)
rg "oidc\s*=\s*\{" hosts/forge/services/ --type nix -A 15
cat hosts/forge/services/paperless.nix  # Native OIDC example
cat hosts/forge/services/mealie.nix  # Container OIDC example
cat hosts/forge/services/autobrr.nix  # Simple OIDC example

# Discover container healthcheck patterns
rg "healthcheck.enable" hosts/forge/services/ --type nix -B 2 -A 2

# Discover NFS mount patterns (for media services)
rg "nfsMountDependency" --type nix -A 3
rg "reverseProxy.enable" --type nix -A 3

# Discover systemd hardening
rg "NoNewPrivileges" --type nix -A 10

# ADVANCED PATTERNS (study if service needs these):

# Discover database integration patterns
rg "modules.services.postgresql.databases" --type nix -A 10

# Discover MQTT integration patterns
rg "modules.services.emqx.integrations" --type nix -A 10

# Discover Grafana integration patterns
rg "modules.services.grafana.integrations" --type nix -A 10

# Discover preseed/restore patterns
rg "preseed.enable" --type nix -A 5
rg "restoreMethods" --type nix -A 3

# Discover user/UID allocations (CRITICAL - must be unique)
rg "uid = [0-9]+" --no-heading | sort -t'=' -k2 -n | tail -20
rg "gid = [0-9]+" --no-heading | sort -t'=' -k2 -n | tail -20

# Discover LoadCredential patterns (container secrets)
rg "LoadCredential" --type nix -A 5

# Discover custom type definitions
rg "types.submodule" --type nix -A 15 hosts/_modules/nixos/services/teslamate/

# OPTIONAL HOST-LEVEL INTEGRATIONS:

# Discover Cloudflare Tunnel integration (public access opt-in)
rg "cloudflare.enable" --type nix -A 3
rg "cloudflare.tunnel" --type nix -A 2
cat hosts/forge/services/pocketid.nix  # Example with cloudflare

# FORGE DEFAULTS LIBRARY (reduces host-level boilerplate):
cat hosts/forge/lib/defaults.nix
rg "forgeDefaults" --type nix -A 2
```

### Step 2: Extract and Document Patterns

From your study, you MUST document these patterns:

**Port conventions:**
- What port range do services use?
- How are metrics ports assigned relative to main port?
- **ALWAYS scan for port conflicts before assigning**

**User/UID conventions:**
- What UID range do services use? (typically 900-999)
- Which UIDs are already allocated?
- **ALWAYS scan for UID conflicts before assigning**
- For media services, use shared `media` group instead of service-specific group

**Domain patterns:**
- How are reverse proxy domains constructed?
- What's the relationship between service name and domain?

**Storage patterns:**
- Where are datasets mounted?
- What recordsize for different workload types?
- What compression settings are standard?
- What snapshot settings are used?

**Backup patterns:**
- What paths are backed up?
- How are backup configurations structured?
- Any patterns for backup frequency or retention?

**Monitoring patterns:**
- How do services expose metrics?
- How do they register with Prometheus?
- What's the Gatus contribution pattern?

**Service user patterns:**
- What's the naming convention?
- What groups are services typically in?
- What permissions are standard?

**Systemd hardening baseline:**
- What directives appear in every service?
- What's the standard privilege model?
- What filesystem protections are applied?

**Integration patterns:**
- How do services declare reverse proxy needs?
- How do they register with monitoring?
- How do they declare backup requirements?

**Advanced integration patterns** (if applicable):
- How does teslamate provision its PostgreSQL database?
- How does teslamate register with EMQX for MQTT?
- How does teslamate provision Grafana datasources and dashboards?
- What's the LoadCredential pattern for container secrets?
- When are custom types created (extensionSpecType, etc.)?

**Optional host-level integrations:**
- How do services opt into Cloudflare Tunnel for public access?
- Where is this configured (module vs host)?
- When should services be publicly accessible?

**forgeDefaults helper library:**
- What helpers are available for alerts, sanoid, preseed, caddySecurity?
- When should you use `mkServiceDownAlert` vs `mkSystemdServiceDownAlert`?
- How does `mkSanoidDataset` configure ZFS replication?
- How does `mkPreseed` configure disaster recovery?

### Step 3: Assess Service Complexity

Before forming your plan, classify the target service:

**Simple service** (like dispatcharr):
- Single-purpose utility
- No database requirements
- No external integrations beyond reverse proxy
- Basic monitoring/backup needs
- **Reference**: dispatcharr

**Moderate service** (like sonarr/radarr):
- Native systemd service OR simple container
- Standard integrations (reverse proxy, backup, metrics)
- Straightforward configuration
- No complex external dependencies
- **Reference**: sonarr, radarr

**Complex service** (like teslamate):
- Requires database (PostgreSQL, etc.)
- Multiple external integrations (MQTT, Grafana, etc.)
- Container-based with credential management
- Custom configuration types needed
- Preseed/restore capability required
- **Reference**: teslamate

**Match your implementation approach to service complexity:**

For **Simple** services:
- Follow dispatcharr pattern
- Minimal submodules (just reverse proxy, basic monitoring)
- No advanced integrations

For **Moderate** services:
- Follow sonarr/radarr pattern
- Full standard submodules (reverseProxy, metrics, backup, notifications)
- No database or external service integrations

For **Complex** services:
- Study teslamate thoroughly
- Use advanced integration patterns:
  * `modules.services.postgresql.databases` for DB provisioning
  * `modules.services.emqx.integrations` for MQTT
  * `modules.services.grafana.integrations` for dashboards
  * `LoadCredential` for container secrets
  * Custom types for structured configuration
  * Preseed submodule for disaster recovery

### Step 4: Research Upstream (if needed)

**After completing Step 0 (NixOS package research)**, if you still need:
- Default ports
- Data directory structure
- Common configuration patterns
- Security considerations

Use perplexity_research:

```
[TOOL CALL RATIONALE]
Current understanding: [what you know about the service]
Why perplexity_research: Need current upstream defaults and NixOS deployment patterns
What I expect: default ports, data directories, systemd vs container guidance, security notes
Alternative: Could guess based on similar services, but want authoritative info
```

Query: "Best practices for running [SERVICE] on NixOS/Linux homelab: default ports, data directories, user/group, systemd vs container, security considerations, common pitfalls"

**For container-based services, also determine:**
- Docker Hub or GitHub Container Registry image name
- Latest stable version tag (NOT `:latest`)
- Container's exposed ports (internal)
- Required environment variables
- Volume mount expectations

### Step 4b: Fetch Container Image Digest (if container service)

**If the service will use a container, fetch the pinned digest.**

**Registry preference order:**
1. **GitHub Container Registry (ghcr.io)** - preferred, better rate limits, often more current
2. **Quay.io** - good alternative
3. **Docker Hub** - use only if no GHCR/Quay option exists

```bash
# Check if GHCR image exists (preferred)
skopeo inspect docker://ghcr.io/myservice/app:v1.2.3

# Get latest stable version tag, then fetch the immutable digest

# Option 1: Using crane (preferred - no pull required)
nix shell nixpkgs#crane -c crane digest ghcr.io/myservice/app:v1.2.3

# Option 2: Using skopeo
skopeo inspect docker://myservice/app:v1.2.3 | jq -r '.Digest'

# Option 3: Docker (requires pulling the image)
docker pull myservice/app:v1.2.3
docker inspect --format='{{index .RepoDigests 0}}' myservice/app:v1.2.3
```

**Document the result:**
```
CONTAINER IMAGE:
- Registry: ghcr.io (preferred) or docker.io (fallback)
- Image: myservice/app
- Tag: v1.2.3 (latest stable as of YYYY-MM-DD)
- Digest: sha256:abc123def456...
- Full reference: ghcr.io/myservice/app:v1.2.3@sha256:abc123def456...
- Docker Hub fallback: (only if no GHCR available)
```

### Step 5: Port Conflict Scanning (REQUIRED)

**Before assigning any port, scan the repository for conflicts:**

```bash
# Search for the upstream default port
rg "port.*=.*8080" --type nix
rg ":8080" --type nix
rg "8080" --type nix | head -20

# If conflicts found, try adjacent ports
rg "port.*=.*8081" --type nix
rg ":8081" --type nix

# Check common port ranges used in repo
rg "port.*=.*[0-9]{4}" --type nix | sort | uniq -c | sort -rn | head -20
```

**Port assignment rules:**
1. **First choice**: Use upstream's default port if available
2. **If conflict**: Increment by 100 (e.g., 8080 → 8180 → 8280)
3. **Document conflict**: Note in module why non-default port was chosen
4. **Avoid busy ranges**: 8080-8099 often crowded, consider 8300+ for new services

**Example conflict resolution:**
```nix
port = mkOption {
  type = types.port;
  default = 8380;  # Upstream default is 8080, but used by qbittorrent
  description = "Port for service. Changed from upstream default (8080) to avoid conflict.";
};
```

### Step 6: Form Preliminary Plan

Based on discovered patterns, upstream research, and **service complexity tier**, create a 90% complete plan:

**Show your work:**
```
COMPLEXITY ASSESSMENT: [Simple/Moderate/Complex]
Reasoning: [why you classified it this way]

Based on pattern study, I propose:

MODULE STRUCTURE (following [reference] pattern):
---
services.<servicename> = {
  enable = mkEnableOption "<service>";
  port = mkOption { default = <port>; };  # From upstream, fits observed range

  # Standard submodules (ALL services):
  reverseProxy = {
    enable = mkEnableOption "reverse proxy";
    domain = mkOption { default = "<service>.${config.networking.domain}"; };
  };

  metrics = {
    enable = mkEnableOption "metrics";
    port = mkOption { default = <port+1>; };
  };

  backup = {
    enable = mkEnableOption "backups";
    paths = mkOption { default = [ "/var/lib/<service>" ]; };
  };

  # IF COMPLEX: Database integration (teslamate pattern)
  database = mkIf <needs-database> {
    host = mkOption { default = "host.containers.internal"; };
    port = mkOption { default = 5432; };
    name = mkOption { default = "<service>"; };
    user = mkOption { default = "<service>"; };
    passwordFile = mkOption { type = types.nullOr types.path; };
    manageDatabase = mkOption { type = types.bool; default = true; };
    extensions = mkOption { ... };  # If PostgreSQL extensions needed
  };

  # IF COMPLEX: MQTT integration (teslamate pattern)
  mqtt = mkIf <needs-mqtt> {
    enable = mkEnableOption "MQTT publishing";
    host = mkOption { default = "127.0.0.1"; };
    port = mkOption { default = 1883; };
    username = mkOption { ... };
    passwordFile = mkOption { ... };
    registerEmqxIntegration = mkOption { type = types.bool; default = true; };
  };

  # IF COMPLEX: Grafana integration (teslamate pattern)
  grafanaIntegration = mkIf <needs-grafana> {
    enable = mkEnableOption "Grafana dashboards";
    folder = mkOption { ... };
    datasourceName = mkOption { ... };
    dashboardsPath = mkOption { ... };
  };

  # IF COMPLEX: Preseed/restore (teslamate pattern)
  preseed = mkIf <needs-preseed> {
    enable = mkEnableOption "automatic restore";
    repositoryUrl = mkOption { ... };
    restoreMethods = mkOption { default = ["syncoid" "local" "restic"]; };
  };
};

STORAGE CONFIGURATION (following observed patterns):
---
modules.storage.datasets."<service>" = {
  type = "zfs_fs";
  mountpoint = "/var/lib/<service>";  # Standard mount pattern
  properties = {
    recordsize = "<128K|16K|...>";  # Based on workload type
    compression = "lz4";  # Standard from all services (or "zstd" for db-heavy)
    "com.sun:auto-snapshot" = "true";  # Standard from all services
  };
};

Recordsize reasoning:
- 128K: Media workload (matches sonarr/radarr)
- 16K: Database workload (matches teslamate)
- 1M: Large sequential files

SYSTEMD SERVICE (following hardening pattern):
---
systemd.services.<service> = {
  serviceConfig = {
    User = "<service>";
    Group = "<service>";

    # Baseline hardening from all services:
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadWritePaths = [ "/var/lib/<service>" ];

    # IF COMPLEX: LoadCredential pattern for containers (teslamate)
    LoadCredential = mkIf <is-container> [
      "db_password:${cfg.database.passwordFile}"
      "api_key:${cfg.apiKeyFile}"
    ];
  };

  # IF COMPLEX: Build env file from credentials (teslamate pattern)
  preStart = mkIf <is-container> ''
    install -d -m 700 /run/<service>
    {
      printf "DATABASE_PASS=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/db_password")"
      printf "API_KEY=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/api_key")"
    } > /run/<service>/env
  '';
};

ADVANCED INTEGRATIONS (if complex service):
---
# Database provisioning (teslamate pattern):
modules.services.postgresql.databases.${cfg.database.name} = mkIf cfg.database.manageDatabase {
  owner = cfg.database.user;
  ownerPasswordFile = cfg.database.passwordFile;
  extensions = cfg.database.extensions;
};

# MQTT registration (teslamate pattern):
modules.services.emqx.integrations.${serviceName} = mkIf cfg.mqtt.registerEmqxIntegration {
  users = [{ username = cfg.mqtt.username; passwordFile = cfg.mqtt.passwordFile; }];
  acls = [{ permission = "allow"; topics = cfg.mqtt.aclTopics; }];
};

# Grafana integration (teslamate pattern):
modules.services.grafana.integrations.${serviceName} = mkIf cfg.grafanaIntegration.enable {
  datasources.${serviceName} = { type = "postgres"; ... };
  dashboards.${serviceName} = { path = cfg.grafanaIntegration.dashboardsPath; };
};

BASIC INTEGRATIONS (auto-registration pattern):
---
- Caddy reverse proxy: auto-configured via services.<service>.reverseProxy.enable
- Prometheus: auto-configured via services.<service>.metrics.enable
- Backup: auto-configured via services.<service>.backup.enable
- Gatus: add endpoint contribution via modules.services.gatus.contributions.<service>
- Homepage: add dashboard entry via modules.services.homepage.contributions.<service>

DEFAULT INTEGRATIONS (REQUIRED for services with web endpoints):
---
For ANY service with a web UI or API endpoint, you MUST add:

1. **Homepage contribution** (dashboard entry with optional widget):
```nix
modules.services.homepage.contributions.<service> = {
  group = "<Category>";  # e.g., "Media", "Monitoring", "Infrastructure"
  name = "<Display Name>";
  icon = "<service>";  # Icon name from dashboard-icons
  href = "https://<service>.holthome.net";
  description = "<brief description>";
  siteMonitor = "http://localhost:<port>";  # Internal health check URL
  # Optional: Add widget if service has a supported Homepage widget
  # See: https://gethomepage.dev/widgets/services/
  widget = {
    type = "<service>";
    url = "http://localhost:<port>";
    key = "{{HOMEPAGE_VAR_<SERVICE>_API_KEY}}";  # If API key needed
  };
};
```

2. **Gatus contribution** (black-box monitoring):
```nix
modules.services.gatus.contributions.<service> = {
  name = "<Display Name>";
  group = "<Category>";  # e.g., "Media", "Services", "Infrastructure"
  url = "https://<service>.holthome.net";  # External URL to monitor
  interval = "60s";
  conditions = [
    "[STATUS] == 200"
    "[RESPONSE_TIME] < 1000"  # Adjust threshold as appropriate
  ];
};
```

**Integration Decision Matrix:**
| Service Type | Homepage | Gatus | Notes |
|-------------|----------|-------|-------|
| Web UI (user-facing) | ✅ Required | ✅ Required | Both for visibility |
| API-only service | ✅ Optional | ✅ Required | Gatus monitors health |
| Database/Backend | ❌ No | ❌ Optional | Internal services, Prometheus monitors |
| Infrastructure | ✅ If browseable | ✅ If external endpoint | Case by case |

HOST CONFIGURATION (following forge pattern):
---
# hosts/forge/services/<service>.nix
let
  serviceEnabled = config.modules.services.<service>.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.<service> = {
        enable = true;
        reverseProxy.enable = true;
        metrics.enable = true;
        backup.enable = true;

        # IF COMPLEX: Database config
        database = mkIf <needs-db> {
          passwordFile = config.sops.secrets."<service>/database_password".path;
        };

        # IF COMPLEX: MQTT config
        mqtt = mkIf <needs-mqtt> {
          enable = true;
          passwordFile = config.sops.secrets."<service>/mqtt_password".path;
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.<service> = { ... };
      modules.backup.sanoid.datasets."tank/services/<service>" = { ... };
      modules.alerting.rules."<service>-service-down" = { ... };

      # REQUIRED for services with web endpoints:
      # Homepage dashboard contribution
      modules.services.homepage.contributions.<service> = {
        group = "<Category>";
        name = "<DisplayName>";
        icon = "<service>";
        href = "https://<service>.holthome.net";
        description = "<brief description>";
        siteMonitor = "http://localhost:<port>";
        # Add widget if supported by Homepage
        widget = { ... };  # Optional
      };

      # Gatus black-box monitoring
      modules.services.gatus.contributions.<service> = {
        name = "<DisplayName>";
        group = "<Category>";
        url = "https://<service>.holthome.net";
        interval = "60s";
        conditions = [ "[STATUS] == 200" ];
      };
    })
  ];
}

# Guard Requirement:
# Any host-level contribution outside the module itself (datasets, alerts, backup jobs,
# Cloudflare tunnels, etc.) MUST be wrapped in `lib.mkIf serviceEnabled`. Disabling the
# service should automatically drop all downstream infrastructure.

# OPTIONAL: Enable public access via Cloudflare Tunnel
# Only add if service should be accessible from the internet
modules.services.caddy.virtualHosts.<service>.cloudflare = mkIf <needs-public-access> {
  enable = true;
  tunnel = "forge";  # Or other tunnel name
};
```

---

## Quality Gate: Evidence of Pattern Study

**BEFORE asking user questions, you MUST demonstrate:**

✓ **Evidence you read the files:**
Show excerpts from sonarr/radarr that informed your decisions:
```
From sonarr/default.nix (lines X-Y), I found:
[show actual code snippet]

This tells me [pattern you extracted]
```

✓ **Pattern extraction summary:**
List the specific patterns you discovered and will follow

✓ **Preliminary module structure:**
Show 90% complete code based on patterns

✓ **Reasoning for choices:**
Explain why you chose specific values based on patterns

**DO NOT proceed until you can show this evidence.**

---

## User Input (Only After Pattern Study)

Present your findings and plan first, THEN ask only targeted questions:

### Presentation Format:
```
I completed NixOS package research and studied existing service modules.

NIXOS PACKAGE RESEARCH (Step 0):
- Package name: <name>
- Stable version: <version> (nixos-24.11)
- Unstable version: <version> (nixos-unstable)
- Native service module: services.<name>.enable (Y/N)
- Decision: [Native module | pkgs.unstable | pkgs | Container]
- Reasoning: [why this choice]

PATTERNS DISCOVERED:
- Port range: Services use 7000-9000, metrics at port+1
- Domains: <service>.${config.networking.domain}
- Storage: /var/lib/<service> with workload-specific recordsize
- Backup: All services include /var/lib/<service> in backup paths
- Monitoring: All expose Prometheus metrics, auto-register
- Systemd: Baseline hardening includes NoNewPrivileges, PrivateTmp, ProtectSystem=strict

PROPOSED PLAN FOR [SERVICE]:
[Show your 90% complete plan based on patterns]

INTEGRATIONS (enabled by default for web services):
- Homepage: [group, widget type if supported]
- Gatus: [monitoring URL and conditions]

QUESTIONS I CANNOT ANSWER FROM PATTERNS:
1. [Targeted question about service-specific detail]
2. [Hardware requirement question]
3. [Secret-specific question]

Does this plan match your expectations, or should anything be different?
```

### What to Ask (ONLY if not discoverable):

**Service-specific unknowns:**
- Secrets beyond service defaults (API keys, OAuth)
- Hardware requirements (GPU, special devices)
- Specific version constraints
- Expected data volume (if impacts dataset planning)

**Integration-specific questions** (for complex services):
- "This service uses PostgreSQL. Should I use `modules.services.postgresql.databases` for automatic provisioning?"
- "I see this service can publish telemetry. Should it integrate with EMQX like teslamate?"
- "This service has visualization capabilities. Should I provision Grafana datasources and dashboards?"
- "Do you want preseed/restore capability (like teslamate) for disaster recovery?"
- "I see the service needs multiple secrets. Should I use the LoadCredential pattern (teslamate) or mount files directly?"

**Public access questions:**
- "Should this service be accessible from the internet via Cloudflare Tunnel?"
- "If public: Is authentication already handled (caddy-security/PocketID, built-in auth, etc.)?"

**Confirmation:**
- "Does my pattern-based plan look correct?"
- "Any deviations from standard patterns needed?"

### What NOT to Ask:
❌ "What port should it use?" - Infer from upstream + existing range
❌ "What should the domain be?" - Pattern is obvious: `<service>.${config.networking.domain}`
❌ "What recordsize?" - Infer from workload type (media=128K, db=16K)
❌ "Where to store data?" - Standard pattern: `/var/lib/<service>`
❌ "How to integrate monitoring?" - Pattern exists, auto-registration
❌ "What backup paths?" - Standard pattern in all services
❌ "What systemd hardening?" - Baseline is in all services

---

## Implementation Workflow

### 1. Planning Phase
Use zen.planner to structure your pattern-based plan:
- Module options (based on discovered patterns)
- Storage datasets (based on workload type)
- Backup configuration (based on standard pattern)
- Monitoring integration (based on auto-registration)
- Host integration (based on forge examples)

### 2. Critique Phase
Use zen.challenge on your plan:
- Verify alignment with discovered patterns
- Check for over-engineering
- Validate security hardening completeness
- Ensure no pattern deviations without justification

Present refined plan to user for approval.

### 3. Implementation (iterative)

Create files in order:
1. **Module skeleton**: `hosts/_modules/nixos/services/<service>/default.nix`
   - Options block (following pattern)
   - Defaults based on pattern study

2. **Service definition**
   - systemd service or container (justify if container)
   - User/group (following naming pattern)
   - Baseline hardening directives

3. **Storage datasets**
   - Following discovered structure
   - Recordsize based on workload
   - Standard compression/snapshot settings

4. **Integration submodules**
   - reverseProxy auto-registration
   - metrics auto-registration
   - backup auto-registration

5. **Host integration**: `hosts/forge/services/<service>.nix`
   - Import forgeDefaults library
   - Enable service with standard backup/preseed
   - Use `forgeDefaults.mkSanoidDataset` for ZFS replication
   - Use `forgeDefaults.mkServiceDownAlert` or `mkSystemdServiceDownAlert` for monitoring
   - Any host-specific overrides

### 4. Validation

```bash
# Build test
task nix:build-forge

# Flake check
nix flake check

# Show results
[paste actual output]
```

Do NOT suggest `task nix:apply-nixos` until user approves.

---

## Constraints

### Pattern Adherence
✅ **MUST follow discovered patterns** unless justified deviation
❌ Don't invent new patterns when existing ones work

### Feature Integration Decision Matrix

**Use this matrix to determine which integrations to enable:**

| Feature | Enable When | Skip When |
|---------|-------------|-----------|
| **Homepage** | Has web UI | API-only or internal service |
| **Gatus** | User-facing endpoint | Internal service or covered by another check |
| **Native OIDC** | Multi-user, complex roles (user folders, permissions) | Single-user or simple access control |
| **Trusted Header** | Multi-user, supports auth proxy (Remote-User) | No proxy auth support |
| **caddySecurity** | Single-user app (disable native auth if possible) | Multi-user or has native OIDC |
| **Hybrid Auth** | Has API key but native auth can't be disabled | Auth disableable or has proxy auth |
| **healthcheck.enable** | Container service | Native systemd service |
| **nfsMountDependency** | Needs NAS access (media, documents) | Self-contained data |
| **mkBackupWithSnapshots** | Database or application state | Stateless or ephemeral data |
| **preseed** | Critical service, DR needed | Trivial to recreate |
| **mkSanoidDataset** | Needs ZFS replication to NAS | No replication needed |
| **Cloudflare Tunnel** | Public access (no VPN) | Internal-only or VPN access |

**Authentication decision priority (ALWAYS research auth options first):**
1. ✅ **Native OIDC** → Best for apps with user roles/permissions (paperless, mealie)
2. ✅ **Trusted Header Auth** → Multi-user via auth proxy (Remote-User header)
3. ✅ **Disable native auth + caddySecurity** → Preferred for single-user apps
4. ✅ **Hybrid Auth** → When API key exists but native auth can't be disabled
5. ⚠️ **Built-in Auth only** → Last resort when nothing else works
6. ❌ **None** → Only for truly internal S2S services

**Common service profiles:**

- **Media arr service** (sonarr, radarr): Homepage ✅, Gatus ✅, nfsMountDependency ✅, backup ✅, **caddySecurity** (disable native auth)
- **Media server** (plex): Homepage ✅, Gatus ✅, nfsMountDependency ✅, **Built-in auth** (can't disable, has own users)
- **Multi-user dashboard** (grafana): Homepage ✅, Gatus ✅, **Trusted Header Auth** ✅ (auth.proxy + Remote-User)
- **Multi-user web app** (paperless, mealie): Homepage ✅, Gatus ✅, **Native OIDC** ✅ (per-user data), preseed ✅
- **Single-user utility** (paperless-ai): Homepage ✅, Gatus ✅, **Hybrid Auth** ✅ (can't disable auth), backup ✅
- **Internal API** (arr-webhook, S2S): Homepage ❌, Gatus ❌, mkStaticApiKey ✅
- **Infrastructure** (DNS, monitoring): Homepage ❌, Gatus ✅ (health), alerts ✅

### Native Preference
✅ **ALWAYS complete Step 0** (NixOS MCP research) to check for native packages/modules
✅ **Prefer**: Native systemd service using NixOS module (like home-assistant, gatus)
✅ **Second choice**: Native package from nixpkgs with custom systemd wrapper (like sonarr/radarr)
✅ **Use `pkgs.unstable`** when unstable has significantly newer/better version
❌ **Avoid**: Container unless:
  - Not in nixpkgs (stable or unstable) and hard to package
  - Upstream only ships containers
  - Needs hardware isolation

**Decision tree:**
1. Check `mcp_nixos_nixos_search` for native module → Use native NixOS service
2. Check for package in unstable → Use `pkgs.unstable.<package>`
3. Check for package in stable → Use `pkgs.<package>`
4. No package available → Container (document justification)

Document justification if using container.

### Container Image Pinning (REQUIRED for containers)

When using OCI containers, **ALWAYS pin images with SHA256 digest**.

**Registry preference:** GHCR (`ghcr.io`) > Quay (`quay.io`) > Docker Hub (`docker.io`)

```nix
# ❌ Wrong - mutable tag, breaks reproducibility
image = mkOption {
  type = types.str;
  default = "myservice/app:latest";  # Never use :latest
};

# ❌ Also wrong - version tag without digest
image = mkOption {
  type = types.str;
  default = "myservice/app:v1.2.3";  # Tags can be overwritten
};

# ✅ Correct - GHCR with versioned tag and SHA256 digest
image = mkOption {
  type = types.str;
  default = "ghcr.io/myservice/app:v1.2.3@sha256:abc123def456...";  # Immutable, GHCR preferred
  description = ''Container image with pinned digest for reproducibility.'';
};
```

**How to get the digest:**
```bash
# For Docker Hub images
docker pull myservice/app:v1.2.3
docker inspect --format='{{index .RepoDigests 0}}' myservice/app:v1.2.3

# Or use crane (preferred - doesn't require pulling)
nix shell nixpkgs#crane -c crane digest myservice/app:v1.2.3

# Or use skopeo
skopeo inspect docker://myservice/app:v1.2.3 | jq -r '.Digest'
```

**Version and registry selection priority:**
1. **GHCR image** (`ghcr.io/...`) - preferred registry, better rate limits
2. **Latest stable release tag** (e.g., `v1.2.3`) - preferred version
3. **Latest minor release** if patch versions are frequent
4. **Avoid** Docker Hub if GHCR available - rate limited, less reliable
5. **Avoid** `:latest` - it's a moving target, breaks reproducibility
6. **Avoid** commit SHA tags unless no releases exist

**Document in module:**
```nix
image = mkOption {
  type = types.str;
  # Renovate: datasource=docker depName=ghcr.io/myservice/app
  default = "ghcr.io/myservice/app:v1.2.3@sha256:abc123...";
  description = ''Container image (GHCR preferred). Update via Renovate or manually with crane digest.'';
};
```

### User and Group Management (CRITICAL)

**ALWAYS disable DynamicUser and create stable UID/GID for service users.**

#### Why Stable UIDs Matter

- DynamicUser creates random UIDs at runtime - breaks file ownership across rebuilds
- ZFS datasets, NFS mounts, and backups depend on consistent UID/GID
- Native NixOS modules often create users conditionally - wrappers must override

#### UID Allocation Process

**1. Scan for existing UIDs BEFORE choosing one:**
```bash
# Search for all UID definitions in the repo
rg "uid = [0-9]+" --no-heading | sort -t'=' -k2 -n | tail -20

# Or check a specific UID
rg "uid = 918" --no-heading
```

**2. Choose a UID in the 900-999 range that's not already used.**

Known allocations (as of 2025-06):
- 918: profilarr
- 919: autobrr
- 920: tdarr
- 921: cross-seed
- 922: recyclarr
- 930: pinchflat

**3. Document your allocation in the module:**
```nix
uid = mkOption {
  type = types.int;
  default = 9XX;  # Replace with your allocated UID
  description = "UID for <service> user (must be unique across hosts)";
};
```

#### Native Module Wrapper Pattern

When wrapping a native NixOS module that conditionally creates users, you **MUST use `lib.mkForce`** to override the native module's user definition:

```nix
# ❌ WRONG - Native module may also create user, causing conflicts
users.users.${cfg.user} = {
  isSystemUser = true;
  group = cfg.group;
  uid = cfg.uid;
};

# ✅ CORRECT - mkForce ensures our definition wins
users.users.${cfg.user} = lib.mkForce {
  isSystemUser = true;
  group = cfg.group;
  uid = cfg.uid;
  home = "/var/empty";  # Prevent permission issues with StateDirectory
  createHome = false;
};

users.groups.${cfg.group} = lib.mkForce {
  gid = cfg.gid;
};
```

**Why mkForce?** Native modules like `services.pinchflat` often include:
```nix
users.users.pinchflat = lib.mkIf (cfg.user == "pinchflat") { ... };
```

Without mkForce, NixOS will try to merge both definitions, potentially causing:
- Duplicate user definition errors
- Missing UID (native module may not set one)
- Wrong group membership

#### Media Service User Pattern

For services accessing shared media (Plex, Sonarr, Radarr, Pinchflat, etc.):

```nix
# User definition in module
users.users.${cfg.user} = lib.mkForce {
  isSystemUser = true;
  group = cfg.group;
  uid = cfg.uid;
  home = "/var/empty";
  createHome = false;
  extraGroups = [ "media" ];  # Access to shared media files
};

# Host config sets the group to "media"
modules.services.pinchflat = {
  group = "media";  # Shared media group instead of service-specific
  uid = 930;        # Unique, stable UID
};
```

### Security Mandates (from pattern study)
```nix
# Minimum baseline (found in ALL services):
serviceConfig = {
  User = "<service>";              # Never root
  Group = "<service>";
  NoNewPrivileges = true;          # Required
  PrivateTmp = true;               # Required
  ProtectSystem = "strict";        # Required
  ProtectHome = true;              # Required
  ReadWritePaths = [ "/var/lib/<service>" ];  # Explicit
};
```

All secrets via SOPS (no exceptions).

### Storage Pattern (from pattern study)
```nix
modules.storage.datasets."<service>" = {
  type = "zfs_fs";
  mountpoint = "/var/lib/<service>";
  properties = {
    recordsize = "<based on workload>";
    compression = "lz4";
    "com.sun:auto-snapshot" = "true";
  };
};
```

### Integration Pattern (from pattern study)
```nix
services.<service> = {
  enable = true;
  reverseProxy.enable = true;  # Auto-registers with Caddy
  metrics.enable = true;        # Auto-registers with Prometheus
  backup.enable = true;         # Auto-registers with Restic
};
```

### forgeDefaults Library (Host-Level Pattern)

The `hosts/forge/lib/defaults.nix` library reduces duplication in host service files:

```nix
{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.<service>.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.<service> = {
        enable = true;
        backup = forgeDefaults.backup;  # Standard NAS backup
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" "restic" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS replication to NAS
      modules.backup.sanoid.datasets."tank/services/<service>" =
        forgeDefaults.mkSanoidDataset "<service>";

      # Service availability alert (container services)
      modules.alerting.rules."<service>-service-down" =
        forgeDefaults.mkServiceDownAlert "<service>" "DisplayName" "description";

      # OR for native systemd services:
      modules.alerting.rules."<service>-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "<service>" "DisplayName" "description";
    })
  ];
}
```

**Available helpers:**
- `forgeDefaults.backup` - Standard NAS backup config
- `forgeDefaults.mkBackupWithSnapshots serviceName` - Backup with ZFS snapshots
- `forgeDefaults.mkBackupWithTags serviceName tags` - Backup with ZFS + custom tags
- `forgeDefaults.backupTags.*` - Standard tag sets: `.media`, `.iptv`, `.home`, `.infrastructure`, `.database`, `.monitoring`, `.downloads`
- `forgeDefaults.mkPreseed restoreMethods` - DR preseed (auto-gated by restic)
- `forgeDefaults.mkSanoidDataset serviceName` - ZFS snapshot/replication config
- `forgeDefaults.mkServiceDownAlert name display desc` - Container alert
- `forgeDefaults.mkSystemdServiceDownAlert name display desc` - Systemd alert
- `forgeDefaults.mkHealthcheckStaleAlert name display thresholdSeconds` - Healthcheck staleness
- `forgeDefaults.caddySecurity.media/admin/home` - PocketID authentication
- `forgeDefaults.podmanNetwork` - Standard Podman network name ("media-services")
- `forgeDefaults.mkStaticApiKey name envVar` - S2S API key authentication

**Backup with tags example:**
```nix
# Media service with standard tags
backup = forgeDefaults.mkBackupWithTags "sonarr" (forgeDefaults.backupTags.media ++ [ "forge" ]);

# Document service with custom tags
backup = forgeDefaults.mkBackupWithTags "paperless" [ "documents" "paperless" "forge" ];
```

---

## Additional Integration Patterns

### OIDC/PocketID Integration Pattern

**ALWAYS research authentication options for each service:**
1. Can native auth be disabled?
2. Does the app need multi-user authorization (user X can access Y)?

**Key Principle:** Prefer consistent SSO via caddySecurity over per-app auth, UNLESS
the app needs per-user authorization (e.g., user-specific folders, permissions, meal plans).

**Authentication Priority Order:**
1. ✅ **Native OIDC** - Best for apps with complex user/role management (paperless, mealie)
2. ✅ **Trusted Header Auth** - Great for multi-user apps supporting auth proxy (grafana, organizr)
3. ✅ **Disable native auth + caddySecurity** - Preferred for single-user apps, consistent SSO
4. ✅ **Hybrid Auth** (SSO + API key) - When auth can't be disabled but has API key
5. ⚠️ **Built-in Auth only** - Last resort when nothing else works
6. ❌ **No auth** - Only for truly internal services

#### Pattern 1: Native OIDC (For Multi-User Authorization)

**For services with built-in OIDC/OAuth2 support** (paperless, mealie, autobrr, etc.):

```nix
# Standard OIDC configuration (from paperless)
oidc = {
  enable = true;
  serverUrl = "https://id.${config.networking.domain}/.well-known/openid-configuration";
  clientId = "<service>";
  clientSecretFile = config.sops.secrets."<service>/oidc_client_secret".path;
  providerId = "pocketid";
  providerName = "Holthome SSO";
  autoSignup = true;
  autoRedirect = true;  # Skip local login, go straight to SSO
  disableLocalLogin = false;  # Keep as fallback
};

# Container services often use slightly different config:
oidc = {
  enable = true;
  issuer = "https://id.${config.networking.domain}";
  clientId = "<service>";
  clientSecretFile = config.sops.secrets."<service>/oidc-client-secret".path;
  redirectUrl = "https://<service>.${config.networking.domain}/api/auth/oidc/callback";
  disableBuiltInLogin = false;
};
```

#### Pattern 2: Disable Native Auth + caddySecurity (PREFERRED for Single-User)

**For single-user apps where you don't need per-user authorization:**

This is the preferred pattern for most homelab services. Disable native auth
and use caddySecurity for consistent SSO experience across all apps.

```nix
# Example: arr apps (sonarr, radarr, etc.)
modules.services.sonarr = {
  enable = true;
  # Disable native authentication
  authentication = "DisabledForLocalAddresses";  # or similar option
  # ... other config

  reverseProxy = {
    enable = true;
    hostName = serviceDomain;
    # PocketID SSO - consistent auth across all apps
    caddySecurity = forgeDefaults.caddySecurity.media;  # or .home, .admin
  };
};
```

**When to use this pattern:**
- ✅ Single user or household access (everyone has same permissions)
- ✅ No per-user folders, permissions, or authorization needed
- ✅ App supports disabling native authentication
- ✅ Want consistent SSO experience across all apps

**Research checklist:**
1. Does the app have an option to disable authentication?
2. Look for: `authentication = "None"`, `auth.enabled = false`, `DISABLE_AUTH=true`, etc.
3. If auth can be disabled → use this pattern

#### Pattern 3: Trusted Header Auth (Auth Proxy Pattern)

**For multi-user apps that trust proxy-injected user identity headers:**

This is the **best pattern for multi-user apps** when they support it. The app trusts
headers from Caddy/PocketID and creates/maps users automatically based on email/username.

```nix
# Example from Grafana (auth.proxy mode):
services.grafana.settings = {
  auth.proxy = {
    enabled = true;
    header_name = "Remote-User";      # or "X-Forwarded-User", "X-Email"
    header_property = "username";      # or "email"
    auto_sign_up = true;               # Auto-create users on first login
  };
};

# Caddy injects the header after PocketID auth:
reverseProxy = {
  enable = true;
  hostName = serviceDomain;
  caddySecurity = forgeDefaults.caddySecurity.admins;
  # PocketID/Caddy automatically injects Remote-User header
};
```

**How it works:**
1. User accesses `https://grafana.holthome.net`
2. Caddy redirects to PocketID for SSO login
3. PocketID authenticates user (passkey, password, etc.)
4. Caddy injects `Remote-User: user@holthome.net` header
5. App trusts header, creates/maps user, grants appropriate permissions
6. User has per-user experience with SSO convenience

**When to use this pattern:**
- ✅ App supports "auth proxy" or "trusted header" authentication
- ✅ Multi-user app where per-user permissions/data matter
- ✅ Want SSO convenience without configuring OIDC in each app
- ✅ Common headers: `Remote-User`, `X-Forwarded-User`, `X-Email`, `X-Forwarded-Email`

**Research checklist:**
1. Does the app support "auth proxy" or "trusted headers" mode?
2. Look for: `auth.proxy.enabled`, `ENABLE_HTTP_REMOTE_USER`, `trustedProxies`, `proxy_auth`
3. What header does it expect? (`Remote-User`, `X-Email`, etc.)
4. Does it auto-create users or require pre-provisioning?

**Examples of apps supporting this:**
- Grafana (`auth.proxy`)
- Organizr (`REMOTE_USER`)
- Many PHP apps (via `REMOTE_USER` CGI variable)
- Some Python apps (via `X-Forwarded-User`)

#### Pattern 4: Hybrid Auth (SSO + API Key Injection)

**For services that have API key auth but native auth CAN'T be disabled** (like paperless-ai):

This pattern uses PocketID at the proxy level for user authentication, then injects
an API key header to bypass the service's internal auth:

```nix
# Example from paperless-ai:
reverseProxy = {
  enable = true;
  hostName = serviceDomain;
  backend = {
    host = "127.0.0.1";
    port = listenPort;
  };
  # PocketID SSO at proxy level
  caddySecurity = forgeDefaults.caddySecurity.home;
  # Inject API key header to bypass internal service auth
  reverseProxyBlock = ''
    header_up x-api-key {$SERVICE_API_KEY}
  '';
};

# The service also needs apiKeyFile configured:
apiKeyFile = config.sops.secrets."<service>/api_key".path;
```

**How it works:**
1. User accesses `https://service.holthome.net`
2. Caddy redirects to PocketID for SSO login
3. After successful auth, Caddy injects `x-api-key` header
4. Service accepts request as authenticated via API key
5. User sees the UI without additional login prompts

**Note:** This pattern does NOT preserve user identity - everyone shares the same
API key and thus the same "user" in the app. Use Pattern 3 (Trusted Header) for
multi-user scenarios when the app supports it.

**SOPS secrets required for hybrid auth:**
```yaml
<service>:
  api_key: "<api-key-for-header-injection>"
```

**Caddy environment variable:**
The `{$SERVICE_API_KEY}` syntax reads from Caddy's environment. The module should
expose this via systemd's `LoadCredential` or environment file.

#### Pattern 5: caddySecurity Only (Last Resort)

**Only for services with NO authentication support:**

```nix
reverseProxy = {
  enable = true;
  hostName = serviceDomain;
  caddySecurity = forgeDefaults.caddySecurity.home;  # or .media, .admin
};
```

**OIDC Decision Matrix:**
| Scenario | Auth Pattern | Example |
|----------|--------------|----------|
| Multi-user, complex roles/permissions | Native OIDC ✅ | paperless, mealie |
| Multi-user, supports auth proxy headers | Trusted Header Auth ✅ | grafana, organizr |
| Single-user, auth can be disabled | Disable + caddySecurity ✅ | arr apps, dashboards |
| Can't disable auth, has API key | Hybrid (SSO + API key) ✅ | paperless-ai |
| Auth can't be disabled, no API key | Built-in auth only ⚠️ | plex |
| Internal-only API | None or staticApiKeys | S2S services |

**SOPS secrets required for native OIDC:**
```yaml
<service>:
  oidc_client_secret: "<client-secret-from-pocketid>"
```
```

### Container Healthcheck Pattern

**For container-based services**, enable healthcheck monitoring:

```nix
modules.services.<service> = {
  enable = true;
  healthcheck.enable = true;  # Enables container health monitoring
  # ...
};
```

This exposes metrics via the container health exporter for Prometheus.

### NFS Mount Dependency Pattern

**For services needing NAS access** (media libraries, document storage):

```nix
modules.services.<service> = {
  enable = true;
  nfsMountDependency = "media";  # Name of NFS mount in modules.storage.nfsMounts
  # ...
};
```

This ensures:
1. Service waits for NFS mount before starting
2. Service has proper access to shared storage
3. Automatic media library path configuration (for arr services)

### Complex Alerting with monitoring-helpers

**For services needing custom Prometheus alerts**, use `mylib.monitoring-helpers`:

```nix
{ config, lib, mylib, ... }:  # Note: mylib must be in function args

modules.alerting.rules = {
  # Basic threshold alert
  "plex-down" = mylib.monitoring-helpers.mkThresholdAlert {
    name = "plex";
    alertname = "PlexDown";
    expr = "plex_up == 0";
    for = "5m";
    severity = "critical";
    category = "availability";
    summary = "Plex is down on {{ $labels.instance }}";
    description = "Plex healthcheck failing. Check: systemctl status plex.service";
  };

  # Healthcheck staleness (using forgeDefaults)
  "plex-healthcheck-stale" = forgeDefaults.mkHealthcheckStaleAlert "plex" "Plex" 600;
};
```

**Available monitoring-helpers:**
- `mkServiceDownAlert { job, name, for, severity, category, description }` - Service up metric check
- `mkThresholdAlert { name, alertname, expr, for, severity, service, category, summary, description }` - Custom expression
- `mkHighMemoryAlert { job, name, threshold, for, severity, category }` - Memory usage
- `mkHighCpuAlert { job, name, threshold, for, severity, category }` - CPU usage
- `mkHighResponseTimeAlert { job, name, threshold, for, severity, category }` - HTTP latency
- `mkDatabaseConnectionsAlert { name, expr, for, severity, category }` - DB connections

### Gatus Alert Configuration Pattern

**Gatus contributions should include proper alerting:**

```nix
modules.services.gatus.contributions.<service> = {
  name = "<Display Name>";
  group = "<Category>";
  url = "https://<service>.holthome.net";
  interval = "60s";
  conditions = [
    "[STATUS] == 200"
    "[RESPONSE_TIME] < 5000"  # 5 second timeout
  ];
  alerts = [{
    type = "pushover";
    enabled = true;
    failureThreshold = 3;      # Alert after 3 consecutive failures
    successThreshold = 2;      # Resolve after 2 consecutive successes
    sendOnResolved = true;     # Notify when service recovers
    description = "<Service> is not responding";
  }];
};
```

---

## Advanced Integration Patterns (Complex Services)

If your service is **complex** (needs database, MQTT, Grafana, etc.), study teslamate and use these patterns:

### Database Provisioning Pattern (teslamate)

**Don't manually configure database:**
```nix
# ❌ Wrong - manual database setup
systemd.services.postgresql-init-mydb = {
  script = ''
    psql -c "CREATE DATABASE mydb"
    psql -c "CREATE USER myuser"
  '';
};
```

**Do use the standardized integration:**
```nix
# ✅ Correct - teslamate pattern
modules.services.postgresql.databases.${cfg.database.name} = mkIf cfg.database.manageDatabase {
  owner = cfg.database.user;
  ownerPasswordFile = cfg.database.passwordFile;
  extensions = cfg.database.extensions;
  permissionsPolicy = "owner-readwrite+readonly-select";
  schemaMigrations = cfg.database.schemaMigrations;  # Optional Ecto support
};
```

**Define extensions properly:**
```nix
# In module options:
database.extensions = mkOption {
  type = types.listOf (types.coercedTo types.str (name: { inherit name; }) extensionSpecType);
  default = [
    { name = "pgcrypto"; }
    { name = "postgis"; dropBeforeCreate = true; updateToLatest = true; }
  ];
};

# Custom type for structured extension config:
extensionSpecType = types.submodule {
  options = {
    name = mkOption { type = types.str; };
    schema = mkOption { type = types.nullOr types.str; default = null; };
    dropBeforeCreate = mkOption { type = types.bool; default = false; };
    updateToLatest = mkOption { type = types.bool; default = false; };
  };
};
```

### MQTT Integration Pattern (teslamate)

**Don't manually configure MQTT:**
```nix
# ❌ Wrong - no integration with broker
services.myservice.mqtt.enable = true;
# User must manually add to EMQX config
```

**Do auto-register with EMQX:**
```nix
# ✅ Correct - teslamate pattern
modules.services.emqx.integrations.${serviceName} = mkIf (
  cfg.mqtt.enable
  && cfg.mqtt.registerEmqxIntegration
) {
  users = [
    {
      username = cfg.mqtt.username;
      passwordFile = cfg.mqtt.passwordFile;
      tags = [ serviceName "telemetry" ];
    }
  ];
  acls = [
    {
      permission = "allow";
      action = "pubsub";
      subject = {
        kind = "user";
        value = cfg.mqtt.username;
      };
      topics = cfg.mqtt.aclTopics;
      comment = "${serviceName} telemetry topics";
    }
  ];
};
```

### Grafana Integration Pattern (teslamate)

**Don't manually configure datasources:**
```nix
# ❌ Wrong - manual Grafana config
# User must add datasource through UI
```

**Do provision datasources and dashboards:**
```nix
# ✅ Correct - teslamate pattern
modules.services.grafana.integrations.${serviceName} = mkIf cfg.grafanaIntegration.enable {
  datasources.${serviceName} = {
    name = cfg.grafanaIntegration.datasourceName;
    uid = cfg.grafanaIntegration.datasourceUid;
    type = "postgres";  # or "prometheus", "influxdb", etc.
    access = "proxy";
    url = "${cfg.database.host}:${toString cfg.database.port}";
    user = cfg.database.user;
    database = cfg.database.name;
    jsonData = {
      sslmode = "disable";
      timescaledb = false;
    };
    secureJsonData = {
      password = "$__file{${grafanaCredentialPath}}";
    };
  };

  dashboards.${serviceName} = {
    name = "${serviceName} Dashboards";
    folder = cfg.grafanaIntegration.folder;
    path = cfg.grafanaIntegration.dashboardsPath;  # Directory of JSON files
  };

  loadCredentials = [ "${grafanaCredentialName}:${cfg.database.passwordFile}" ];
};
```

**Fetch upstream dashboards:**
```nix
# At top of module:
let
  dashboardsSrc = pkgs.fetchzip {
    url = "https://github.com/project/repo/archive/refs/tags/v1.0.0.tar.gz";
    sha256 = "sha256-...";
  };
  defaultDashboardsPath = "${dashboardsSrc}/grafana/dashboards";
in
```

### LoadCredential Pattern for Containers (teslamate)

**Don't mount secret files directly:**
```nix
# ❌ Wrong - exposes secret file paths to container
virtualisation.oci-containers.containers.myservice = {
  volumes = [
    "${cfg.passwordFile}:/run/secrets/password:ro"  # Don't do this
  ];
};
```

**Do use systemd LoadCredential:**
```nix
# ✅ Correct - teslamate pattern
systemd.services."${backend}-${serviceName}" = {
  serviceConfig = {
    LoadCredential = [
      "db_password:${cfg.database.passwordFile}"
      "api_key:${cfg.apiKeyFile}"
      "mqtt_password:${cfg.mqtt.passwordFile}"
    ];
  };

  preStart = ''
    set -euo pipefail
    install -d -m 700 /run/${serviceName}
    tmp="/run/${serviceName}/env.tmp"
    trap 'rm -f "$tmp"' EXIT

    # Build environment file from credentials
    {
      printf "DATABASE_PASS=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/db_password")"
      printf "API_KEY=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/api_key")"
      printf "MQTT_PASSWORD=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/mqtt_password")"
    } > "$tmp"

    install -m 600 "$tmp" /run/${serviceName}/env
  '';
};

# Then use in container:
virtualisation.oci-containers.containers.${serviceName} = {
  environmentFiles = [ "/run/${serviceName}/env" ];
  # No secret volumes needed!
};
```

### Preseed/Restore Pattern (teslamate)

**For services needing disaster recovery:**
```nix
# In module options:
preseed = {
  enable = mkEnableOption "automatic Restic/ZFS restore before first start";
  repositoryUrl = mkOption { type = types.str; };
  passwordFile = mkOption { type = types.nullOr types.path; };
  restoreMethods = mkOption {
    type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
    default = [ "syncoid" "local" "restic" ];
  };
};

# In config:
(mkIf (cfg.enable && cfg.preseed.enable) (
  storageHelpers.mkPreseedService {
    serviceName = serviceName;
    dataset = datasetPath;
    mountpoint = cfg.dataDir;
    mainServiceUnit = mainServiceUnit;
    replicationCfg = replicationConfig;
    resticRepoUrl = cfg.preseed.repositoryUrl;
    resticPasswordFile = cfg.preseed.passwordFile;
    restoreMethods = cfg.preseed.restoreMethods;
  }
))
```

### Custom Types for Complex Configuration (teslamate)

**When to create custom types:**
- Multiple related configuration options
- Structured data (like database extensions)
- Reusable configuration blocks

**Example from teslamate:**
```nix
# For PostgreSQL extensions with advanced options:
extensionSpecType = types.submodule {
  options = {
    name = mkOption {
      type = types.str;
      description = "Extension name";
    };
    schema = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional schema for CREATE EXTENSION";
    };
    version = mkOption {
      type = types.nullOr types.str;
      default = null;
    };
    dropBeforeCreate = mkOption {
      type = types.bool;
      default = false;
    };
    updateToLatest = mkOption {
      type = types.bool;
      default = false;
    };
  };
};

# Then use with coercion for convenience:
database.extensions = mkOption {
  type = types.listOf (types.coercedTo types.str (name: { inherit name; }) extensionSpecType);
  # Allows both: ["pgcrypto"] and [{ name = "pgcrypto"; dropBeforeCreate = true; }]
};
```

---

## Optional Host-Level Integrations

Some integrations are configured **at the host level** rather than in the module definition. These are opt-in features that apply to specific deployments.

### Cloudflare Tunnel (Public Internet Access)

**What it is:**
Cloudflare Tunnel provides secure external access to services without opening firewall ports. Services opt in at the host level via Caddy virtualHost configuration.

**Discovery:**
```bash
# Find services using Cloudflare Tunnel
rg "cloudflare.enable" --type nix -A 3
rg "cloudflare.tunnel" --type nix

# Example service
cat hosts/forge/services/pocketid.nix
```

**Pattern (Module remains unchanged):**
```nix
# In module: Just provide reverse proxy capability
services.myservice = {
  enable = mkEnableOption "myservice";

  reverseProxy = {
    enable = mkEnableOption "reverse proxy";
    hostName = mkOption {
      type = types.str;
      default = "myservice.${config.networking.domain}";
    };
  };
};

# Module config section:
modules.services.caddy.virtualHosts.${serviceName} = mkIf cfg.reverseProxy.enable {
  enable = true;
  hostName = cfg.reverseProxy.hostName;
  backend = { ... };
};
```

**Pattern (Host opts in to public access):**
```nix
# In host config: hosts/forge/services/myservice.nix
{ config, ... }:
{
  config = {
    # Standard service configuration
    modules.services.myservice = {
      enable = true;
      reverseProxy.enable = true;
      metrics.enable = true;
      backup.enable = true;
    };

    # Cloudflare Tunnel opt-in (OPTIONAL)
    # Only add if service should be accessible from the internet
    modules.services.caddy.virtualHosts.myservice.cloudflare = {
      enable = true;
      tunnel = "forge";  # Tunnel name configured in cloudflared module
    };
  };
}
```

**How it works:**
1. cloudflared module discovers services via `findTunneledVhosts` helper
2. Services with `cloudflare.enable = true` are added to tunnel ingress
3. DNS records are automatically created (if configured)
4. Traffic flows: Internet → Cloudflare → Tunnel → Caddy → Service

**When to use:**
- ✅ Service needs internet access (remote access, webhooks, etc.)
- ✅ Service is already secured (caddy-security/PocketID, built-in auth, API keys)
- ✅ Public exposure is intentional and necessary
- ❌ Don't expose unauthenticated services
- ❌ Don't expose if LAN-only access is sufficient

**Security considerations:**
```nix
# Example: Public service with caddy-security/PocketID protection
modules.services.caddy.virtualHosts.myservice = {
  enable = true;
  hostName = "myservice.${config.networking.domain}";

  # Require authentication via PocketID SSO
  caddySecurity = {
    enable = true;
    portal = "pocketid";
    policy = "default";
    allowedGroups = [ "admins" ];
  };

  # Enable public access
  cloudflare = {
    enable = true;
    tunnel = "forge";
  };
};
```

**Ask user:**
- "Should this service be accessible from the internet?"
- "If yes: Does it have authentication (caddy-security/PocketID, built-in, API keys)?"
- "What's the use case for public access (remote access, webhooks, sharing)?"
- "What's the use case for public access (remote access, webhooks, sharing)?"

**Common services using Cloudflare Tunnel:**
- PocketID (SSO login portal - must be public)
- Services with webhooks (autobrr, dispatcharr)
- Shared services (recipe manager, photo galleries)
- Remote access dashboards (with SSO)

**Common services NOT using Cloudflare Tunnel:**
- Internal tools (Prometheus, Grafana - unless specifically shared)
- Media servers (use VPN instead)
- Infrastructure services (PostgreSQL, MQTT)
- Admin interfaces (use Tailscale/WireGuard)

---

## Anti-Patterns to Avoid

### ❌ Asking questions before studying patterns
```
User: "Add Jellyfin"
LLM: "What port? What domain? What storage?"
# You should know this from patterns!
```

### ✅ Study first, ask targeted questions
```
User: "Add Jellyfin"
LLM: [reads sonarr/radarr]
LLM: "Based on patterns, here's my plan: [detailed plan]
Only question: Will you use GPU transcoding?"
```

---

### ❌ Hardcoded domains
```nix
domain = "jellyfin.holthome.net";  # Wrong - breaks pattern
```

### ✅ Pattern-based domains
```nix
domain = "jellyfin.${config.networking.domain}";  # Correct - matches all services
```

---

### ❌ Running as root
```nix
User = "root";  # Never - violates pattern
```

### ✅ Dedicated user (pattern)
```nix
User = "jellyfin";
Group = "jellyfin";
```

---

### ❌ Skipping auto-registration
```nix
# Wrong - manual integration elsewhere
services.jellyfin.enable = true;
```

### ✅ Using discovered integration pattern
```nix
# Correct - follows all service patterns
services.jellyfin = {
  enable = true;
  reverseProxy.enable = true;
  metrics.enable = true;
  backup.enable = true;
};
```

---

### ❌ Inventing new recordsize without reasoning
```nix
recordsize = "64K";  # Why? Other media services use 128K
```

### ✅ Following pattern with reasoning
```nix
recordsize = "128K";  # Media workload, matches sonarr/radarr pattern
```

---

### ❌ Using :latest, unpinned, or Docker Hub when GHCR available
```nix
image = "myservice/app:latest";  # Wrong - mutable, breaks reproducibility
image = "myservice/app:v1.2.3";  # Wrong - tags can be overwritten
image = "docker.io/myservice/app:v1.2.3@sha256:...";  # Wrong if GHCR exists
```

### ✅ GHCR with pinned SHA256 digest
```nix
image = "ghcr.io/myservice/app:v1.2.3@sha256:abc123...";  # Correct - GHCR + immutable
```

---

### ❌ Assigning ports without checking for conflicts
```nix
port = 8080;  # Wrong - didn't check if already used
```

### ✅ Scanning repo before port assignment
```bash
# First: rg "8080" --type nix  # Check for conflicts
# If conflict: choose different port and document why
```
```nix
port = 8380;  # Upstream default 8080 conflicts with qbittorrent
```

---

## Deliverables

### 1. NixOS Package Research Evidence (Step 0)
Show your MCP research results:
```
NIXOS PACKAGE RESEARCH:
- Package name: <name>
- Stable version: <version> (nixos-24.11)
- Unstable version: <version> (nixos-unstable)
- Native service module: services.<name>.enable (Y/N)
- NixOS module options explored: [list key options if native module exists]
- Decision: [Native module | pkgs.unstable | pkgs | Container]
- Reasoning: [why this choice]
```

### 2. Pattern Study Evidence
Show what you learned:
```
PATTERN STUDY SUMMARY:
From sonarr/radarr/scrypted, I discovered:
- [Port patterns with examples]
- [Domain patterns with examples]
- [Storage patterns with examples]
- [Integration patterns with examples]
[etc.]
```

### 3. Preliminary Plan (Before User Input)
90% complete plan based on patterns:
```nix
# Module structure
# Storage datasets
# Service definition
# Integration configuration
# Host integration (including Homepage + Gatus contributions)
```

### 4. Implementation Files
After user approval:
- `hosts/_modules/nixos/services/<service>/default.nix`
- `hosts/forge/services/<service>.nix`
- Support files if needed

### 5. Documentation
- Pattern alignment explanation
- Storage recordsize rationale
- Any deviations from patterns (justified)
- Integration points (auto-registered)
- **Homepage integration:** Group, widget type (if applicable), API key secret (if needed)
- **Gatus monitoring:** Endpoint URL, conditions, interval
- **Public access decision:**
  - Is service exposed via Cloudflare Tunnel? (Y/N)
  - If yes: Authentication mechanism (caddy-security/PocketID, built-in, API keys)
  - If yes: Justification for public exposure
  - If no: Access method (LAN-only, VPN, etc.)

### 6. Validation Results
```bash
$ task nix:build-forge
[actual output]

$ nix flake check
[actual output]

# Any warnings or errors explained
```

### 7. Follow-up Checklist
```
REQUIRED BEFORE DEPLOYMENT:
- [ ] Add secrets to SOPS: [exact commands]
  sops secrets/forge.yaml
  # Add: <service>.api_key = "xxx"
  # Add: HOMEPAGE_VAR_<SERVICE>_API_KEY (if widget needs API key)
  # Add: <service>.oidc_client_secret (if OIDC enabled)

- [ ] OIDC/PocketID setup: [if applicable]
  # Create client in PocketID admin
  # Set redirect URL: https://<service>.holthome.net/callback
  # Copy client secret to SOPS

- [ ] DNS records: [if needed]
  <service>.holthome.net → <forge-ip>

- [ ] Firewall verification: [ports]
  Verify ports <X> exposed correctly

- [ ] Manual config: [if any]
  [specific steps]

- [ ] Post-deploy testing:
  curl https://<service>.holthome.net
  systemctl status <service>
  # Verify Homepage widget loads
  # Verify Gatus shows service healthy
  # Verify OIDC login works (if enabled)
```

### 8. Decision Rationale
```
DECISIONS MADE:
- Native vs container: [Native/pkgs.unstable/Container - justify with Step 0 findings]
- Package source: [pkgs | pkgs.unstable | container image] - [reason]
- Storage recordsize: [128K - media workload like sonarr/radarr]
- Pattern deviations: [None - all patterns followed]
- Security considerations: [Baseline hardening applied, SOPS for secrets]
- Authentication: [OIDC/caddySecurity/none] - [reason]
- NFS mount dependency: [Yes/No] - [reason if Yes]
```

---

## Success Criteria

You've succeeded when:

✓ Completed Step 0 (NixOS MCP research + auth research) BEFORE any other work
✓ Used native package/module when available (checked both unstable and stable)
✓ Used `pkgs.unstable` when unstable has better version
✓ **Researched ALL auth options**: OIDC? Trusted headers? Auth disableable? API key?
✓ Used Native OIDC for complex multi-user apps with roles/permissions
✓ Used Trusted Header Auth when app supports auth proxy (Remote-User)
✓ Disabled native auth + used caddySecurity for single-user apps (preferred)
✓ Used hybrid auth only when native auth can't be disabled
✓ User didn't have to answer questions you could have discovered from patterns
✓ Plan matches existing service structure at appropriate complexity level
  - Simple → dispatcharr-like
  - Moderate → sonarr/radarr-like
  - Complex → teslamate-like with advanced integrations
✓ All choices are justified by pattern or upstream documentation
✓ User only had to answer service-specific unknowns
✓ Implementation mirrors existing quality/style
✓ Advanced integrations (DB/MQTT/Grafana) use standardized patterns when needed
✓ Homepage contribution added for web UI services (with widget if supported)
✓ Gatus contribution added for user-facing endpoints (with alert configuration)
✓ healthcheck.enable set for container services
✓ nfsMountDependency set for services needing NAS access
✓ **Stable UID/GID allocated** - scanned repo for conflicts, used mkForce for native module wrappers
✓ Validation passes cleanly
✓ User can deploy with confidence

---

## References

**Follow these instructions:**
- `.github/copilot-instructions.md` - Tool orchestration
- `.github/instructions/nixos-instructions.md` - NixOS patterns
- `.github/instructions/security-instructions.md` - Security requirements

**Study these patterns (by complexity):**

*Simple services:*
- `hosts/_modules/nixos/services/dispatcharr/` - Minimal service example

*Moderate services:*
- `hosts/_modules/nixos/services/sonarr/` - Complete media service
- `hosts/_modules/nixos/services/radarr/` - Confirms standard patterns
- `hosts/_modules/nixos/services/scrypted/` - Container-based service

*Complex services (study for database/MQTT/Grafana):*
- `hosts/_modules/nixos/services/teslamate/` - **Advanced integration patterns**
  - PostgreSQL provisioning
  - MQTT/EMQX integration
  - Grafana datasources and dashboards
  - LoadCredential pattern
  - Custom types
  - Preseed capability

*Host integrations:*
- `hosts/forge/services/sonarr.nix` - Standard declaration with forgeDefaults
- `hosts/forge/services/teslamate.nix` - Complex multi-integration example
- `hosts/forge/services/paperless.nix` - **Native OIDC integration example**
- `hosts/forge/services/paperless-ai.nix` - **Hybrid auth example** (SSO + API key injection)
- `hosts/forge/lib/defaults.nix` - **Centralized helpers for alerts, sanoid, preseed**

*Infrastructure patterns:*
- `modules/services/postgresql/` - Database provisioning
- `modules/services/emqx/` - MQTT integration
- `modules/services/grafana/` - Dashboard provisioning
- `modules/services/cloudflared/` - Public access via Cloudflare Tunnel
- `hosts/forge/networking/cloudflared.nix` - Tunnel configuration example
- `lib/monitoring-helpers.nix` - Prometheus alert template functions (`mylib.monitoring-helpers`)

**Reference these docs:**
- `docs/modular-design-patterns.md` - Architecture principles, forgeDefaults patterns
- `docs/authentication-sso-pattern.md` - **SSO patterns: OIDC, auth proxy, caddySecurity**
- `docs/persistence-quick-reference.md` - Storage details
- `docs/backup-system-onboarding.md` - Backup integration
- `docs/monitoring-strategy.md` - Monitoring details
- `hosts/forge/README.md` - Host architecture, forgeDefaults documentation

---

**Remember: Study patterns FIRST, assess complexity, match implementation to service tier. Most answers are already in the code - simple services follow dispatcharr, moderate follow sonarr/radarr, complex follow teslamate.**
