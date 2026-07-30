# Dispatcharr Database Integration

This module demonstrates the **security-hardened** PostgreSQL database provisioning system in action.

## Security Improvements (2024)

This implementation has been reviewed and hardened based on expert security analysis:

### ✅ Fixed Critical Security Issues

1. **SQL Injection Prevention**: All SQL identifiers use proper `quoteSqlIdentifier` function instead of shell escaping
2. **TLS Security**: Upgraded to `verify-full` SSL mode with certificate verification for external connections
3. **Privilege Hierarchy**: Implements complete PostgreSQL privilege model (database/schema/table/default)
4. **REVOKE Logic**: Properly handles permission exceptions with explicit REVOKE statements
5. **Execution Grouping**: Optimized SQL execution with minimal connection changes and `ON_ERROR_STOP`
6. **Backfill Support**: Default privileges automatically backfill existing objects
7. **Sequences/Functions**: Wildcard grants properly cover tables, sequences, and functions

## Architecture Overview

This module uses Dispatcharr's upstream **modular** deployment mode with
external PostgreSQL and Redis. The web and Celery processes run in separate
containers and share only the application data directory.

### Current Configuration

```nix
modules.services.dispatcharr = {
  enable = true;
  database = {
    passwordFile = config.sops.secrets."dispatcharr/db_password".path;
    # host, port, name, user can be customized if needed
  };
  redis.database = 1;
};
```

### Why External PostgreSQL Only?

**Benefits:**

- Centralized database management
- Automated backups via PITR (Point-In-Time Recovery)
- Better monitoring integration
- Clearer resource allocation
- Can share database server with other services
- Proper security isolation (no embedded database or Redis in the web container)
- Easier troubleshooting and maintenance

**Why This Module Uses Modular Mode:**

- Complex file permissions inside monolithic containers
- Separates web and background-worker resource limits and health checks
- Difficult to backup and restore embedded databases
- Poor observability for database operations
- Resource contention between application and database

### Components

- **PostgreSQL**: External, managed by NixOS PostgreSQL module
- **Redis**: External native NixOS service using a dedicated database index
- **Web**: Upstream modular web entrypoint (uWSGI, nginx, and Daphne)
- **Celery**: Separate container running Beat plus default and DVR workers

## How It Works

### 1. Database Provisioning (Automatic)

The module automatically declares database requirements:

```nix
modules.services.postgresql.databases.dispatcharr = {
  owner = "dispatcharr";
  ownerPasswordFile = config.sops.secrets."dispatcharr/db_password".path;
  extensions = [
    "btree_gin"  # REQUIRED: GIN index support for Django queries
    "pg_trgm"    # REQUIRED: Trigram matching for text search
  ];
  permissions = {
    dispatcharr = [ "ALL" ];
    readonly = [ "SELECT" ];
  };
};
```

On system activation, the PostgreSQL module:

1. Creates the `dispatcharr` role with password
2. Creates the `dispatcharr` database owned by the role
3. Enables required extensions (`btree_gin`, `pg_trgm`)
4. Grants permissions (ALL to dispatcharr, SELECT to readonly)
5. Exports Prometheus metrics
6. Sends notification on success/failure

**Note on Extensions:** Based on Dispatcharr source code analysis (Django migrations), `btree_gin` and `pg_trgm` are **required** extensions. The provisioning system automatically creates these during database setup.

### 2. SOPS Secret (Manual Setup)

One secret is required:

```yaml
# modules/nixos/services/dispatcharr/secrets.sops.yaml
dispatcharr:
  db_password: <secure-password>
```

This single password is used for:

- Database provisioning (read by postgres user)
- Runtime connection (`POSTGRES_PASSWORD`)

**Why `POSTGRES_PASSWORD_FILE` Doesn't Work:**

Dispatcharr expects individual `POSTGRES_*` variables and does not support the
Docker `_FILE` convention for its password.

The systemd `preStart` script reads the password through `LoadCredential` and
writes a root-only environment file consumed by both containers.

### 3. Container Configuration (Automatic)

The module automatically configures the container:

```nix
# Container environment (static)
environment = {
  DISPATCHARR_ENV = "modular";
  POSTGRES_HOST = "host.containers.internal";
  REDIS_HOST = "host.containers.internal";
  REDIS_DB = "1";
  PUID = "569";
  PGID = "569";
  TZ = "America/New_York";
};

# POSTGRES_PASSWORD generated at runtime via environmentFiles
environmentFiles = [ "/run/dispatcharr/env" ];

# Systemd preStart generates /run/dispatcharr/env with:
# POSTGRES_PASSWORD=<password>
```

**Security Flow (Hardened Implementation):**

1. SOPS secret decrypted to `/run/secrets/dispatcharr-db_password` (mode 0440, owner=root, group=postgres)
2. Systemd `LoadCredential` loads secret into isolated `$CREDENTIALS_DIRECTORY`
3. Systemd `preStart` reads the credential without logging it
4. `POSTGRES_PASSWORD` is written to `/run/dispatcharr/env` (mode 0600)
5. Both containers consume the environment file through Podman
6. Containers connect to PostgreSQL and Redis through the Podman host gateway
7. Celery hands the generated Django secret to UID/GID 569, then drops root
8. Semantic health checks require the default and DVR workers to answer

**Security Hardening Applied:**

- ✅ No password in process list (`/proc/<pid>/cmdline`)
- ✅ No password in systemd journal (even with debug logging)
- ✅ No password passed as command argument
- ✅ Systemd `LoadCredential` for proper credential isolation
- ✅ Host firewall restricts PostgreSQL and Redis to Podman networks
- ✅ Fail-fast error handling (`set -euo pipefail`)
- ✅ SELinux-compatible volume mounts (`:Z` flag)
- ✅ Strong dependency chain (`requires` not `wants`)

### 4. Systemd Dependencies (Automatic)

The service waits for:

- `postgresql.service` - PostgreSQL server running
- `postgresql-provision-databases.service` - Database created and configured
- `redis-default.service` - External Redis running

The Celery unit additionally requires and starts after the web unit. `PartOf`
propagates web restarts to Celery.

## Setup Instructions

### Prerequisites

1. **PostgreSQL enabled on the host:**

   ```nix
   modules.services.postgresql = {
     enable = true;
   };
   ```

2. **SOPS configured:**

   ```nix
   sops.defaultSopsFile = ./secrets.sops.yaml;
   sops.age.keyFile = "/var/lib/sops-nix/key.txt";
   ```

### Step 1: Generate Password

```bash
# Generate secure password
openssl rand -base64 32 > /tmp/db_password
```

### Step 2: Create SOPS Secrets File

```bash
cd modules/nixos/services/dispatcharr

# Copy example
cp secrets.sops.yaml.example secrets.sops.yaml

# Edit with SOPS
sops secrets.sops.yaml

# Paste the generated passwords
# Save and exit
```

### Step 3: Enable Dispatcharr

In your host configuration (e.g., `hosts/forge/default.nix`):

```nix
modules.services.dispatcharr = {
  enable = true;

  # Database configuration (external PostgreSQL)
  database.passwordFile = config.sops.secrets."dispatcharr/db_password".path;

  # Optional: Enable backups
  backup = {
    enable = true;
    repository = "primary";
  };

  # Optional: Enable notifications
  notifications.enable = true;
};
```

### Step 4: Deploy

```bash
# Build and activate through the repository guard
task nix:build-nixos host=forge
task nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net
```

### Step 5: Verify

```bash
# Check database was created
ssh forge "sudo -u postgres psql -l | grep dispatcharr"

# Check extensions
ssh forge "sudo -u postgres psql -d dispatcharr -c '\dx'"

# Check both containers are running
ssh forge "sudo podman ps | grep dispatcharr"

# Check container logs
ssh forge "sudo journalctl -u podman-dispatcharr -f"
ssh forge "sudo journalctl -u podman-dispatcharr-celery -f"

# Verify web and worker health
ssh forge "sudo podman healthcheck run dispatcharr"
ssh forge "sudo podman healthcheck run dispatcharr-celery"

# Verify the Plex-facing HDHomeRun interface
ssh forge "curl -fsS http://127.0.0.1:9191/hdhr/discover.json"

# Verify password NOT in process list (security check)
ssh forge "ps aux | grep dispatcharr" | grep -v PASSWORD  # Should show no password

# Verify password NOT in journal (security check)
ssh forge "sudo journalctl -u podman-dispatcharr | grep -i password"  # Should be empty
```

## Troubleshooting

### Database Not Created

Check provisioning service:

```bash
ssh forge "sudo systemctl status postgresql-provision-databases"
ssh forge "sudo journalctl -u postgresql-provision-databases"
```

### Permission Denied

Verify SOPS secret ownership:

```bash
ssh forge "sudo ls -la /run/secrets/ | grep dispatcharr"

# db_owner_password should be owned by postgres
# app_db_password should be owned by dispatcharr (UID 569)
```

### Container Can't Connect

1. Check the generated environment file exists without printing it:

   ```bash
  ssh forge "sudo stat -c '%a %U:%G' /run/dispatcharr/env"
   ```

2. Test connection manually:

   ```bash
   ssh forge "sudo -u postgres psql -d dispatcharr -c 'SELECT version();'"
   ```

3. Check container environment:

   ```bash
  ssh forge "sudo podman exec dispatcharr env | grep -E 'POSTGRES_HOST|REDIS_HOST|DISPATCHARR_ENV'"
   ```

## Monitoring

### Database Metrics

```bash
# Check provisioning metrics
ssh forge "cat /var/lib/node_exporter/textfile_collector/postgresql_databases.prom | grep dispatcharr"

# Check PostgreSQL health
ssh forge "cat /var/lib/node_exporter/textfile_collector/postgresql_health.prom"
```

### Service Health

```bash
# Check Dispatcharr service
ssh forge "sudo systemctl status podman-dispatcharr"
ssh forge "sudo systemctl status podman-dispatcharr-celery"

# Check health checks
ssh forge "sudo podman healthcheck run dispatcharr"
ssh forge "sudo podman healthcheck run dispatcharr-celery"
```

## Benefits of External PostgreSQL

1. **Backups:** Automatic PITR backups with 15-minute WAL archiving
2. **Monitoring:** Prometheus metrics for database health, size, connections
3. **Recovery:** Point-in-time recovery to any second within retention period
4. **Performance:** Better resource allocation and tuning
5. **Maintenance:** Centralized PostgreSQL upgrades and maintenance
6. **Sharing:** Multiple services can use the same PostgreSQL instance
7. **Security:** Proper role separation and permission management
8. **Service Isolation:** Dedicated web, worker, Redis, and PostgreSQL lifecycles

## Security Hardening Details

This implementation keeps credentials out of Nix-generated container
configuration while preserving upstream modular-mode behavior.

### Critical Vulnerabilities Fixed

**1. Process Argument Leak (CRITICAL)**
- **Problem:** Password passed as command-line argument visible in `/proc/<pid>/cmdline`
- **Fix:** Systemd writes it to a root-only Podman environment file
- **Impact:** Password never appears in system process list

**2. Systemd Journal Leak (CRITICAL)**
- **Problem:** Shell expansion in here-doc would log plaintext password to journal
- **Fix:** `printf` writes only to `/run/dispatcharr/env`; the value is never echoed
- **Impact:** Password never logged even with debug logging enabled

**3. Container Network Bug (CRITICAL)**
- **Problem:** Container's `localhost` is isolated namespace - can't reach host PostgreSQL
- **Fix:** Use Podman's `host.containers.internal` gateway alias
- **Impact:** Web and Celery reach the firewall-restricted host services

**4. Missing Error Handling (CRITICAL)**
- **Problem:** No error handling in preStart - failures continue silently
- **Fix:** Added `set -euo pipefail` for fail-fast behavior
- **Impact:** Service fails immediately with clear error messages

**5. Direct SOPS Access (Security Improvement)**
- **Problem:** preStart script directly reads SOPS-managed files
- **Fix:** Use systemd `LoadCredential=` for proper credential isolation
- **Impact:** Leverages systemd's secure credential handling

**6. SELinux Compatibility (Compatibility)**
- **Problem:** Volume mounts need SELinux labels on secure systems
- **Fix:** Added `:Z` flag to data volume mount
- **Impact:** Works correctly on SELinux-enabled systems

**7. Weak Dependency (Reliability)**
- **Problem:** `wants` allows service start even if provisioning fails
- **Fix:** Web requires provisioning and Redis; Celery requires web and Redis
- **Impact:** Clearer failure mode if database provisioning fails

### Security Architecture

```
SOPS Secret (0440, root:postgres)
        │
        ├─► PostgreSQL Provisioning (postgres user)
        │
        └─► systemd LoadCredential
                    │
                    ▼
            $CREDENTIALS_DIRECTORY/db_password
                    │
                └─► printf ───► /run/dispatcharr/env (0600)
                     POSTGRES_PASSWORD=<secret>
                          │
                     ┌────────────────┴────────────────┐
                     ▼                                 ▼
                Modular web container             Celery container
                     │                                 │
                     └──────── Podman gateway ─────────┘
                      │              │
                      ▼              ▼
                     PostgreSQL 17   Redis DB 1
```

### Security Guarantees

✅ **Password Never in Process List**
- Podman reads the root-only environment file instead of a command argument

✅ **Password Never in Logs**
- The pre-start script never prints the generated file or secret value

✅ **Password Never as Command Argument**
- No subprocess receives password as argv, preventing exposure to system monitoring

✅ **Credential Isolation**
- Systemd `LoadCredential` provides proper credential isolation from file access

✅ **Restricted Network Connection**
- PostgreSQL and Redis firewall access is limited to Podman networks

✅ **Non-Root Background Workers**
- The Celery launcher transfers only required file ownership, then permanently
  drops to UID/GID 569 with `setpriv`

✅ **Fail-Fast Error Handling**
- `set -euo pipefail` ensures any failure stops execution immediately

✅ **Strong Dependencies**
- `requires` ensures service won't start if database provisioning fails

✅ **SELinux Compatible**
- `:Z` volume labels ensure proper security context on hardened systems

## Related Documentation

- [PostgreSQL PITR Guide](/docs/postgresql-pitr-guide.md)
- [Database Provisioning Documentation](/docs/postgresql-pitr-guide.md#database-provisioning)
- [SOPS Configuration](/docs/secrets-management.md)
- [Backup System](/docs/backup-system-onboarding.md)
