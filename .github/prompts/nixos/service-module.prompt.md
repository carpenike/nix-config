agent: ask
description: Scaffold a new NixOS service module with storage, backup, and monitoring integrations
version: 2.3
last_updated: 2024-11-20
changelog: "v2.3: Added Cloudflare Tunnel (public access) optional integration pattern. v2.2: Added teslamate as complex service reference, service complexity assessment, advanced integration patterns (DB/MQTT/Grafana), LoadCredential pattern, preseed capability, and custom types guidance"
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

# Discover monitoring patterns
rg "metrics.enable" --type nix -A 3
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

# Discover LoadCredential patterns (container secrets)
rg "LoadCredential" --type nix -A 5

# Discover custom type definitions
rg "types.submodule" --type nix -A 15 hosts/_modules/nixos/services/teslamate/

# OPTIONAL HOST-LEVEL INTEGRATIONS:

# Discover Cloudflare Tunnel integration (public access opt-in)
rg "cloudflare.enable" --type nix -A 3
rg "cloudflare.tunnel" --type nix -A 2
cat hosts/forge/services/authelia.nix  # Example with cloudflare
```

### Step 2: Extract and Document Patterns

From your study, you MUST document these patterns:

**Port conventions:**
- What port range do services use?
- How are metrics ports assigned relative to main port?

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
- What's the Uptime Kuma integration pattern?

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

If you don't know the service's:
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

### Step 5: Form Preliminary Plan

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
- Uptime Kuma: [check if pattern exists]

HOST CONFIGURATION (following forge pattern):
---
# hosts/forge/services/<service>.nix
services.<service> = {
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
I studied the existing service modules (sonarr, radarr, scrypted) and forge host configuration.

PATTERNS DISCOVERED:
- Port range: Services use 7000-9000, metrics at port+1
- Domains: <service>.${config.networking.domain}
- Storage: /var/lib/<service> with workload-specific recordsize
- Backup: All services include /var/lib/<service> in backup paths
- Monitoring: All expose Prometheus metrics, auto-register
- Systemd: Baseline hardening includes NoNewPrivileges, PrivateTmp, ProtectSystem=strict

PROPOSED PLAN FOR [SERVICE]:
[Show your 90% complete plan based on patterns]

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
- "If public: Is authentication already handled (Authelia, built-in auth, etc.)?"

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
   - Enable service
   - Enable standard integrations
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

### Native Preference
✅ **Prefer**: Native systemd service (like sonarr/radarr)
❌ **Avoid**: Container unless:
  - Not in nixpkgs and hard to package
  - Upstream only ships containers
  - Needs hardware isolation

Document justification if using container.

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
cat hosts/forge/services/authelia.nix
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
- ✅ Service is already secured (Authelia, built-in auth, API keys)
- ✅ Public exposure is intentional and necessary
- ❌ Don't expose unauthenticated services
- ❌ Don't expose if LAN-only access is sufficient

**Security considerations:**
```nix
# Example: Public service with Authelia protection
modules.services.caddy.virtualHosts.myservice = {
  enable = true;
  hostName = "myservice.${config.networking.domain}";

  # Require authentication
  authelia = {
    enable = true;
    instance = "main";
    policy = "two_factor";
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
- "If yes: Does it have authentication (Authelia, built-in, API keys)?"
- "What's the use case for public access (remote access, webhooks, sharing)?"

**Common services using Cloudflare Tunnel:**
- Authelia (SSO login portal - must be public)
- Services with webhooks (autobrr, dispatcharr)
- Shared services (recipe manager, photo galleries)
- Remote access dashboards (with 2FA)

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

## Deliverables

### 1. Pattern Study Evidence
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

### 2. Preliminary Plan (Before User Input)
90% complete plan based on patterns:
```nix
# Module structure
# Storage datasets
# Service definition
# Integration configuration
# Host integration
```

### 3. Implementation Files
After user approval:
- `hosts/_modules/nixos/services/<service>/default.nix`
- `hosts/forge/services/<service>.nix`
- Support files if needed

### 4. Documentation
- Pattern alignment explanation
- Storage recordsize rationale
- Any deviations from patterns (justified)
- Integration points (auto-registered)
- **Public access decision:**
  - Is service exposed via Cloudflare Tunnel? (Y/N)
  - If yes: Authentication mechanism (Authelia, built-in, API keys)
  - If yes: Justification for public exposure
  - If no: Access method (LAN-only, VPN, etc.)

### 5. Validation Results
```bash
$ task nix:build-forge
[actual output]

$ nix flake check
[actual output]

# Any warnings or errors explained
```

### 6. Follow-up Checklist
```
REQUIRED BEFORE DEPLOYMENT:
- [ ] Add secrets to SOPS: [exact commands]
  sops secrets/forge.yaml
  # Add: <service>.api_key = "xxx"

- [ ] DNS records: [if needed]
  <service>.holthome.net → <forge-ip>

- [ ] Firewall verification: [ports]
  Verify ports <X> exposed correctly

- [ ] Manual config: [if any]
  [specific steps]

- [ ] Post-deploy testing:
  curl https://<service>.holthome.net
  systemctl status <service>
```

### 7. Decision Rationale
```
DECISIONS MADE:
- Native vs container: [Native - service in nixpkgs, follows pattern]
- Storage recordsize: [128K - media workload like sonarr/radarr]
- Pattern deviations: [None - all patterns followed]
- Security considerations: [Baseline hardening applied, SOPS for secrets]
```

---

## Success Criteria

You've succeeded when:

✓ User didn't have to answer questions you could have discovered from patterns
✓ Plan matches existing service structure at appropriate complexity level
  - Simple → dispatcharr-like
  - Moderate → sonarr/radarr-like
  - Complex → teslamate-like with advanced integrations
✓ All choices are justified by pattern or upstream documentation
✓ User only had to answer service-specific unknowns
✓ Implementation mirrors existing quality/style
✓ Advanced integrations (DB/MQTT/Grafana) use standardized patterns when needed
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
- `hosts/forge/services/sonarr.nix` - Standard declaration
- `hosts/forge/services/teslamate.nix` - Complex multi-integration example

*Infrastructure patterns:*
- `modules/services/postgresql/` - Database provisioning
- `modules/services/emqx/` - MQTT integration
- `modules/services/grafana/` - Dashboard provisioning
- `modules/services/cloudflared/` - Public access via Cloudflare Tunnel
- `hosts/forge/networking/cloudflared.nix` - Tunnel configuration example

**Reference these docs:**
- `docs/modular-design-patterns.md` - Architecture principles
- `docs/persistence-quick-reference.md` - Storage details
- `docs/backup-system-onboarding.md` - Backup integration
- `docs/monitoring-strategy.md` - Monitoring details
- `hosts/forge/README.md` - Host architecture

---

**Remember: Study patterns FIRST, assess complexity, match implementation to service tier. Most answers are already in the code - simple services follow dispatcharr, moderate follow sonarr/radarr, complex follow teslamate.**
