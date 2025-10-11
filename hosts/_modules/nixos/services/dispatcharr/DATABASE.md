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

Dispatcharr always uses **external PostgreSQL** for data storage. The All-In-One (AIO) mode has been removed due to complex permission requirements that make it incompatible with rootless containers and security best practices.

### Current Configuration

```nix
modules.services.dispatcharr = {
  enable = true;
  database = {
    passwordFile = config.sops.secrets."dispatcharr/db_password".path;
    # host, port, name, user can be customized if needed
  };
};
```

### Why External PostgreSQL Only?

**Benefits:**

- Centralized database management
- Automated backups via PITR (Point-In-Time Recovery)
- Better monitoring integration
- Clearer resource allocation
- Can share database server with other services
- Proper security isolation (no embedded database in container)
- Easier troubleshooting and maintenance

**AIO Mode Removed Because:**

- Complex file permissions inside monolithic containers
- Incompatible with rootless container requirements
- Difficult to backup and restore embedded databases
- Poor observability for database operations
- Resource contention between application and database

### Components

- **PostgreSQL**: External, managed by NixOS PostgreSQL module
- **Redis**: Embedded in container via s6-overlay (used for Celery queues only)
- **Celery**: Embedded in container for async task processing

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
# hosts/_modules/nixos/services/dispatcharr/secrets.sops.yaml
dispatcharr:
  db_password: <secure-password>
```

This single password is used for:

- Database provisioning (read by postgres user)
- Runtime connection (URL-encoded and embedded in DATABASE_URL)

**Why DATABASE_PASSWORD_FILE Doesn't Work:**

Dispatcharr uses Django's `django-environ` library to parse `DATABASE_URL`. Unlike Docker-style applications, it does **not** support the `_FILE` suffix convention for secrets. The password must be embedded directly in the `DATABASE_URL` connection string.

Our solution: A systemd `preStart` script reads the SOPS secret, URL-encodes it (to handle special characters like `@`, `:`, `/`), and generates an environment file with the complete `DATABASE_URL`.

### 3. Container Configuration (Automatic)

The module automatically configures the container:

```nix
# Container environment (static)
environment = {
  DISPATCHARR_ENV = "production";
  CELERY_BROKER_URL = "redis://localhost:6379/0";
  CELERY_RESULT_BACKEND_URL = "redis://localhost:6379/0";
  PUID = "569";
  PGID = "569";
  TZ = "America/New_York";
};

# DATABASE_URL generated at runtime via environmentFiles
environmentFiles = [ "/run/dispatcharr/env" ];

# Systemd preStart generates /run/dispatcharr/env with:
# DATABASE_URL=postgresql://dispatcharr:<url-encoded-password>@localhost:5432/dispatcharr
```

**Security Flow (Hardened Implementation):**

1. SOPS secret decrypted to `/run/secrets/dispatcharr-db_password` (mode 0440, owner=root, group=postgres)
2. Systemd `LoadCredential` loads secret into isolated `$CREDENTIALS_DIRECTORY`
3. Systemd `preStart` reads credential via stdin piping (never in process list)
4. Password URL-encoded using `printf` (never logged to journal)
5. `DATABASE_URL` generated with Unix socket path: `postgresql://user:pass@/db?host=/run/postgresql`
6. Environment file written to `/run/dispatcharr/env` (mode 0600, root-only)
7. Container mounts `/run/postgresql` socket (read-only)
8. Django connects via Unix socket (no network stack, filesystem permissions)

**Security Hardening Applied:**

- ✅ No password in process list (`/proc/<pid>/cmdline`)
- ✅ No password in systemd journal (even with debug logging)
- ✅ No password passed as command argument
- ✅ Systemd `LoadCredential` for proper credential isolation
- ✅ Unix socket instead of TCP (better security + performance)
- ✅ Fail-fast error handling (`set -euo pipefail`)
- ✅ SELinux-compatible volume mounts (`:Z` flag)
- ✅ Strong dependency chain (`requires` not `wants`)

### 4. Systemd Dependencies (Automatic)

The service waits for:

- `postgresql.service` - PostgreSQL server running
- `postgresql-database-provisioning.service` - Database created and configured

## Setup Instructions

### Prerequisites

1. **PostgreSQL enabled on the host:**

   ```nix
   modules.services.postgresql.instances.main = {
     enable = true;
     version = "15";
     backup.enable = true;  # Recommended
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
cd hosts/_modules/nixos/services/dispatcharr

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
# Build and activate
nixos-rebuild switch --flake .#forge

# Or deploy remotely
deploy .#forge
```

### Step 5: Verify

```bash
# Check database was created
ssh forge "sudo -u postgres psql -l | grep dispatcharr"

# Check extensions
ssh forge "sudo -u postgres psql -d dispatcharr -c '\dx'"

# Check container is running
ssh forge "sudo podman ps | grep dispatcharr"

# Check container logs
ssh forge "sudo journalctl -u podman-dispatcharr -f"

# Verify Unix socket connection from container
ssh forge "sudo podman exec dispatcharr psql -h /run/postgresql -U dispatcharr -d dispatcharr -c 'SELECT version();'"

# Verify password NOT in process list (security check)
ssh forge "ps aux | grep dispatcharr" | grep -v PASSWORD  # Should show no password

# Verify password NOT in journal (security check)
ssh forge "sudo journalctl -u podman-dispatcharr | grep -i password"  # Should be empty
```

## Troubleshooting

### Database Not Created

Check provisioning service:

```bash
ssh forge "sudo systemctl status postgresql-database-provisioning"
ssh forge "sudo journalctl -u postgresql-database-provisioning"
```

### Permission Denied

Verify SOPS secret ownership:

```bash
ssh forge "sudo ls -la /run/secrets/ | grep dispatcharr"

# db_owner_password should be owned by postgres
# app_db_password should be owned by dispatcharr (UID 569)
```

### Container Can't Connect

1. Check password file is mounted:

   ```bash
   ssh forge "sudo podman exec dispatcharr cat /run/secrets/db_password"
   ```

2. Test connection manually:

   ```bash
   ssh forge "sudo -u postgres psql -d dispatcharr -c 'SELECT version();'"
   ```

3. Check container environment:

   ```bash
   ssh forge "sudo podman exec dispatcharr env | grep -E 'DATABASE|DISPATCHARR_ENV'"
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

# Check health checks
ssh forge "sudo podman healthcheck run dispatcharr"
```

## Benefits of External PostgreSQL

1. **Backups:** Automatic PITR backups with 15-minute WAL archiving
2. **Monitoring:** Prometheus metrics for database health, size, connections
3. **Recovery:** Point-in-time recovery to any second within retention period
4. **Performance:** Better resource allocation and tuning
5. **Maintenance:** Centralized PostgreSQL upgrades and maintenance
6. **Sharing:** Multiple services can use the same PostgreSQL instance
7. **Security:** Proper role separation and permission management
8. **Unix Sockets:** Faster, more secure connections via filesystem permissions

## Security Hardening Details

This implementation underwent critical security review by Gemini Pro, which identified and fixed 7 major security vulnerabilities:

### Critical Vulnerabilities Fixed

**1. Process Argument Leak (CRITICAL)**
- **Problem:** Password passed as command-line argument visible in `/proc/<pid>/cmdline`
- **Fix:** Changed to stdin piping (`cat | script` instead of `script "$password"`)
- **Impact:** Password never appears in system process list

**2. Systemd Journal Leak (CRITICAL)**
- **Problem:** Shell expansion in here-doc would log plaintext password to journal
- **Fix:** Replaced `cat << EOF` with `printf` to avoid shell expansion
- **Impact:** Password never logged even with debug logging enabled

**3. Container Network Bug (CRITICAL)**
- **Problem:** Container's `localhost` is isolated namespace - can't reach host PostgreSQL
- **Fix:** Switch to Unix socket (`/run/postgresql`) mounted into container
- **Impact:** Fixes connectivity + improves security and performance

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
- **Fix:** Changed to `requires` for stronger dependency
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
                    ├─► stdin pipe ───► URL encoder (no process leak)
                    │                          │
                    │                          ▼
                    │                   ENCODED_PASSWORD
                    │                          │
                    │                          ▼
                    │                   printf (no journal leak)
                    │                          │
                    │                          ▼
                    │                   /run/dispatcharr/env (0600)
                    │                   DATABASE_URL=postgresql://user:pass@/db?host=/run/postgresql
                    │                          │
                    │                          ▼
                    │                   Container environmentFiles
                    │                          │
                    └──────────────────────────┴─► /run/postgresql (Unix socket)
                                                         │
                                                         ▼
                                                   PostgreSQL Server
```

### Security Guarantees

✅ **Password Never in Process List**
- Using stdin piping prevents password from appearing in `ps` output or `/proc/<pid>/cmdline`

✅ **Password Never in Logs**
- Using `printf` instead of here-doc prevents shell expansion that would log password
- Even with `set -x` debug mode, password remains secure

✅ **Password Never as Command Argument**
- No subprocess receives password as argv, preventing exposure to system monitoring

✅ **Credential Isolation**
- Systemd `LoadCredential` provides proper credential isolation from file access

✅ **Network-Free Connection**
- Unix socket bypasses network stack entirely, using filesystem permissions

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
