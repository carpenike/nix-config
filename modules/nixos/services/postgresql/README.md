# PostgreSQL Database Provisioning Module

**Status**: Production-Ready (Expert Validated: 9/10)

Declarative NixOS module for managing PostgreSQL databases, roles, permissions, extensions, and security hardening with full idempotency and zero-downtime updates.

## Features

### ✅ Phase 1: Core Database Management
- **Declarative Databases**: Define databases with owners and automatic role creation
- **Extension Management**: Automatic installation of PostgreSQL extensions per database
- **Password Security**: Secure password management via files (never in Nix store or logs)
- **Idempotency**: Safe to run repeatedly; only applies changes when needed
- **Monitoring Integration**: Prometheus metrics for provisioning status

### ✅ Phase 2: Advanced Permissions (Current)
- **Schema Permissions**: USAGE, CREATE grants on custom schemas
- **Table Permissions**: Granular SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER grants
  - Wildcard patterns: `schema.*` for all tables in schema
  - Specific patterns: `schema.table` for individual tables
  - Quoted identifiers: `"My.Schema"."My.Table"` for names with special characters
- **Function/Procedure Permissions**: EXECUTE grants via wildcard patterns
- **Default Privileges**: Automatic grants for future objects (tables, sequences, functions)
  - Includes automatic backfilling to existing objects
- **Security Hardening**: Automatic revocation of PUBLIC permissions
- **Permission Precedence**: Specific patterns override wildcards for fine-tuned control
- **Extension Specs**: Rich extension declarations (schema, version pinning, drop/recreate policies)
- **Custom SQL Hooks**: Pre/post provisioning SQL hooks tied into the change hash
- **Schema Migration Seeding**: Declaratively seed (and optionally prune) migration tables such as `schema_migrations`

## Architecture

### Security Design
- **No Command-Line Exposure**: Passwords read server-side via `pg_read_file()`
- **SQL Injection Prevention**: All identifiers and strings properly quoted/escaped
- **Superuser Isolation**: Provisioning runs as postgres superuser, regular apps use restricted roles
- **Idempotent SQL**: Safe to rerun; uses `DO` blocks with exception handling

### Components
- **database-interface.nix**: Global option declarations (API surface)
- **databases.nix**: Implementation logic (SQL generation and systemd service)
- **Separation**: Allows evaluation on hosts without PostgreSQL enabled

## Usage

### Quick Start: Permission Presets (Recommended)

For most common use cases, use permission presets instead of manually configuring permissions:

```nix
{
  modules.services.postgresql = {
    instances.main = {
      enable = true;
      port = 5432;
    };

    databases = {
      # Simple app with only owner access
      simple_app = {
        owner = "simple_user";
        ownerPasswordFile = "/run/secrets/simple_db_password";
        extensions = [ "uuid-ossp" ];
        permissionsPolicy = "owner-only";  # Most restrictive
      };

      # App with owner + readonly role
      production_app = {
        owner = "myapp_user";
        ownerPasswordFile = "/run/secrets/myapp_db_password";
        extensions = [ "pg_trgm" "btree_gin" ];
        permissionsPolicy = "owner-readwrite+readonly-select";  # Recommended
        # This automatically creates:
        # - 'readonly' role with SELECT on all tables
        # - Full permissions for owner
        # - Default privileges for future objects
      };
    };
  };
}
```

**Available Presets:**
- `owner-only`: Only the database owner has access (most restrictive)
- `owner-readwrite+readonly-select`: Owner has full access + auto-created `readonly` role with SELECT
- `custom`: Manual permission configuration (for advanced use cases)

### Basic Example (Custom Permissions)
```nix
{
  modules.services.postgresql = {
    instances.main = {
      enable = true;
      port = 5432;
    };

    databases = {
      myapp = {
        owner = "myapp_user";
        ownerPasswordFile = "/run/secrets/myapp_db_password";
        extensions = [ "uuid-ossp" "pg_trgm" ];
        permissionsPolicy = "custom";  # Use manual permissions below
      };
    };
  };
}
```

### Structured Extension Specifications

Extensions can be declared as rich objects instead of plain strings. Strings are automatically coerced to `{ name = "ext"; }` for backward compatibility.

```nix
extensions = [
  "pgcrypto"  # Simple string works
  { name = "cube"; dropBeforeCreate = true; dropCascade = true; updateToLatest = true; }
  { name = "earthdistance"; schema = "extensions"; version = "1.1"; }
];
```

Available fields:
- `schema` – optional schema for `CREATE EXTENSION ... WITH SCHEMA`
- `version` – pin to a specific extension version
- `dropBeforeCreate` – drop the extension before recreating it (handy when migrations rebuild objects)
- `dropCascade` – toggle `CASCADE` when dropping
- `updateToLatest` – run `ALTER EXTENSION ... UPDATE` after creation

### Custom SQL Hooks

Per-database SQL snippets can be injected at four hook points. Each hook accepts a list of strings or paths (paths are read during evaluation and included in the provisioning hash).

```nix
customSql = {
  preCreate = [ ''SELECT pg_reload_conf();'' ];          # Runs in postgres DB before CREATE DATABASE
  postCreate = [ ''GRANT CONNECT ON DATABASE myapp TO app_worker;'' ];
  preConfig = [ ''SET ROLE myapp; SELECT 1;'' ];         # Runs inside target DB after hardening
  postConfig = [
    (builtins.readFile ./sql/seed_indexes.sql)
  ];
};
```

Because the snippets are part of the provisioning hash, any change automatically re-runs the provisioning service.

### Schema Migration Seeding

The module can seed application-managed migration tables (e.g., TeslaMate/Ecto `schema_migrations`).

```nix
schemaMigrations = {
  table = "schema_migrations";  # default
  column = "version";           # default
  schema = null;                # optional schema override
  columnType = "varchar(255)"; # used when ensureTable = true
  ensureTable = true;           # create table if missing
  pruneUnknown = true;          # delete rows not listed in entries
  entries = [ "20240929084639" "20240930010255" ];
};
```

- `ensureTable`: Creates the migrations table (with the specified column type) when absent.
- `entries`: Versions inserted idempotently using `ON CONFLICT DO NOTHING`.
- `pruneUnknown`: When true, deletes any row not listed in `entries` (or truncates the table when `entries = []`).

This removes the need for manual superuser intervention when applications expect their migration history to exist before startup.

### Schema Permissions
```nix
{
  modules.services.postgresql.instances.main.databases.myapp = {
    owner = "myapp_user";
    ownerPasswordFile = "/run/secrets/myapp_db_password";

    # Schema-level permissions
    schemaPermissions = {
      public = {
        myapp_user = [ "USAGE" "CREATE" ];
        readonly_user = [ "USAGE" ];
      };
      private_schema = {
        myapp_user = [ "USAGE" "CREATE" ];
      };
    };
  };
}
```

### Table Permissions
```nix
{
  modules.services.postgresql.instances.main.databases.myapp = {
    owner = "myapp_user";

    # Table-level permissions
    tablePermissions = {
      # Wildcard: all tables in schema
      "public.*" = {
        myapp_user = [ "SELECT" "INSERT" "UPDATE" "DELETE" ];
        readonly_user = [ "SELECT" ];
      };

      # Specific table (overrides wildcard)
      "public.sensitive_data" = {
        myapp_user = [ "SELECT" "INSERT" ];
        # readonly_user gets nothing (wildcard overridden)
      };

      # Quoted identifiers for special characters
      ''"My.Schema"."My.Table"'' = {
        myapp_user = [ "SELECT" ];
      };

      # Function execution (requires wildcard)
      "public.*" = {
        myapp_user = [ "EXECUTE" ];
      };
    };
  };
}
```

### Default Privileges (Future Objects)
```nix
{
  modules.services.postgresql.instances.main.databases.myapp = {
    owner = "myapp_user";

    # Permissions for future objects created by myapp_user
    defaultPrivileges = {
      app_tables = {
        forRole = "myapp_user";

        tables = {
          readonly_user = [ "SELECT" ];
          app_worker = [ "SELECT" "INSERT" "UPDATE" ];
        };

        sequences = {
          app_worker = [ "SELECT" "USAGE" "UPDATE" ];
        };

        functions = {
          app_worker = [ "EXECUTE" ];
        };
      };
    };
  };
}
```

### Function Permissions (Separate from Tables)

Function and procedure permissions are now handled separately for clarity:

```nix
{
  modules.services.postgresql.instances.main.databases.myapp = {
    owner = "myapp_user";

    # Function-level permissions
    functionPermissions = {
      # Wildcard: all functions in schema
      "public.*" = {
        myapp_user = [ "EXECUTE" ];
        app_worker = [ "EXECUTE" ];
      };

      # Specific function
      "public.admin_only_function" = {
        admin = [ "EXECUTE" ];
        # myapp_user doesn't get EXECUTE (wildcard overridden)
      };
    };

    # Table permissions (no longer includes EXECUTE)
    tablePermissions = {
      "public.*" = {
        myapp_user = [ "SELECT" "INSERT" "UPDATE" "DELETE" ];
      };
    };
  };
}
```

### Database Metadata Options

Control database creation parameters:

```nix
{
  modules.services.postgresql.instances.main.databases.myapp = {
    owner = "myapp_user";
    ownerPasswordFile = "/run/secrets/myapp_db_password";

    # Database metadata (optional)
    encoding = "UTF8";
    lcCtype = "en_US.UTF-8";     # Character classification (letters, digits, etc.)
    collation = "en_US.UTF-8";   # String sort order (LC_COLLATE)
    template = "template0";      # Use template0 for custom encoding/locale
    tablespace = "fast_ssd";     # Custom tablespace (must exist)

    # Skip provisioning for existing databases
    managed = true;  # default; set to false to skip this database
  };
}
```

### Complete Production Example
```nix
{
  modules.services.postgresql = {
    instances.main.enable = true;

    databases = {
      production_app = {
        owner = "app_owner";
        ownerPasswordFile = "/run/secrets/app_db_password";
        extensions = [ "uuid-ossp" "pg_trgm" "btree_gist" ];

        # Schema permissions
        schemaPermissions = {
          public = {
            app_owner = [ "USAGE" "CREATE" ];
            app_read = [ "USAGE" ];
            app_write = [ "USAGE" ];
          };
        };

        # Table permissions
        tablePermissions = {
          # Base permissions for all tables
          "public.*" = {
            app_owner = [ "ALL" ];
            app_read = [ "SELECT" ];
            app_write = [ "SELECT" "INSERT" "UPDATE" "DELETE" ];
          };

          # Restrict sensitive table
          "public.audit_logs" = {
            app_owner = [ "ALL" ];
            app_read = [ "SELECT" ];
            # app_write gets nothing
          };
        };

        # Future object permissions
        defaultPrivileges = {
          app_defaults = {
            forRole = "app_owner";
            tables = {
              app_read = [ "SELECT" ];
              app_write = [ "SELECT" "INSERT" "UPDATE" "DELETE" ];
            };
            sequences = {
              app_write = [ "SELECT" "USAGE" "UPDATE" ];
            };
          };
        };
      };
    };
  };
}
```

## Permission Precedence Rules

### Table Permissions
1. **Specific patterns override wildcards**:
   - `"public.users"` overrides `"public.*"`
   - Allows restricting access to sensitive tables

2. **Wildcard ordering**:
   - Wildcards processed first (broadest permissions)
   - Specific patterns applied after (restrictions)

3. **Empty permission lists**:
   - Use `[]` to explicitly REVOKE all permissions
   - Useful for exceptions to wildcard grants

### Example
```nix
tablePermissions = {
  # Step 1: Grant read to all tables
  "public.*" = {
    readonly_user = [ "SELECT" ];
  };

  # Step 2: Revoke access to sensitive table
  "public.passwords" = {
    readonly_user = [];  # Explicit revoke
  };
};
```

## Pattern Syntax

### Supported Patterns
The module handles all valid SQL identifier patterns:

1. `schema.table` - Both unquoted
2. `"Schema"."Table"` - Both quoted (preserves case)
3. `"Schema".table` - Quoted schema, unquoted table
4. `schema."Table"` - Unquoted schema, quoted table
5. `schema.*` - Wildcard: all tables in schema
6. `"Schema".*` - Wildcard with quoted schema
7. `table` - Just table name (assumes `public` schema)
8. `"Table"` - Quoted table name (assumes `public` schema)

### Special Characters
Use quoted identifiers for:
- Names with dots: `"my.schema"."my.table"`
- Mixed case: `"MyTable"` (unquoted becomes lowercase)
- Reserved words: `"user"`, `"table"`
- Spaces: `"My Table"`

## Security Best Practices

### 1. Password Management
```nix
# ✅ GOOD: Password in secure file
ownerPasswordFile = "/run/secrets/db_password";

# ❌ BAD: Never put passwords directly in Nix
owner = "myapp";
# No direct password option exists by design
```

### 2. Principle of Least Privilege
```nix
# ✅ GOOD: Separate roles for different access levels
databases.myapp = {
  owner = "myapp_owner";  # DDL operations

  tablePermissions = {
    "public.*" = {
      myapp_read = [ "SELECT" ];           # Read-only
      myapp_write = [ "SELECT" "INSERT" "UPDATE" ];  # No DELETE
    };
  };
};

# ❌ BAD: Everything gets ALL permissions
tablePermissions."public.*".myapp = [ "ALL" ];
```

### 3. Audit Log Protection
```nix
# ✅ GOOD: Restrict sensitive tables
tablePermissions = {
  "public.*" = {
    app_user = [ "SELECT" "INSERT" "UPDATE" "DELETE" ];
  };
  "public.audit_logs" = {
    app_user = [ "SELECT" "INSERT" ];  # Can't modify/delete audit logs
  };
};
```

### 4. Schema Isolation
```nix
# ✅ GOOD: Use schemas for multi-tenancy
schemaPermissions = {
  tenant_a = {
    tenant_a_user = [ "USAGE" "CREATE" ];
    # tenant_b_user gets nothing
  };
  tenant_b = {
    tenant_b_user = [ "USAGE" "CREATE" ];
    # tenant_a_user gets nothing
  };
};
```

## Secret Rotation

Password changes are automatically detected and applied:

```bash
# Update password file
echo "new_password" > /run/secrets/db_password

# Trigger provisioning (automatic on next config change, or manual)
sudo systemctl start postgresql-database-provisioning.service
```

The module computes a combined hash of:
- Database configuration (owners, permissions, extensions)
- Password file **contents** (not just paths)

Changes to either trigger re-provisioning.

## Monitoring

When `modules.monitoring.enable = true`, metrics are exported:

```prometheus
# Provisioning status
postgresql_database_provisioning_last_run_timestamp{instance="main",status="success"} 1696867200

# Check via Node Exporter textfile collector
cat /var/lib/prometheus-node-exporter/postgresql_database_provisioning.prom
```

## Troubleshooting

### Check Provisioning Status
```bash
# View service status
sudo systemctl status postgresql-database-provisioning.service

# View logs
sudo journalctl -u postgresql-database-provisioning.service -f

# Check stamp file
cat /var/lib/postgresql/provisioning/provisioned.sha256
```

### Verify Permissions
```sql
-- Connect as postgres
sudo -u postgres psql

-- Check database permissions
\l+ myapp

-- Check schema permissions
\dn+ public

-- Check table permissions
\dp public.*

-- Check role memberships
\du myapp_user
```

### Force Re-provisioning
```bash
# Remove stamp file to force full re-run
sudo rm /var/lib/postgresql/provisioning/provisioned.sha256
sudo systemctl start postgresql-database-provisioning.service
```

## Permission Override Behavior

When using permission presets with manual permissions:

- **Manual permissions REPLACE preset permissions** for the same role/key
- NOT additive: manual entries completely override preset entries for that specific role
- Example: If preset grants `readonly = ["SELECT"]` on a table, and you manually specify `readonly = ["SELECT", "INSERT"]`, the manual list wins
- To combine: explicitly include all desired privileges in manual configuration

## Limitations

### Current

- **Single PostgreSQL instance**: Multi-instance support planned
- **Local only**: External PostgreSQL servers not yet supported (use `provider = "local"`)
- **No sequence-specific patterns**: Sequences only granted via wildcards
- **No column-level permissions**: Table-level only

### Planned (Future Phases)
- Phase 3: Row-level security policies
- Phase 4: Multi-instance support
- Phase 5: External PostgreSQL provider
- Phase 6: Backup integration hooks

## Implementation Details

### SQL Generation
- Uses `quoteSqlIdentifier` for table/schema/role names (double-quote wrapping with escape-by-doubling)
- Uses `quoteSqlString` for string literals (hash-based dollar-quote tags)
- Pattern parser handles 8 identifier patterns with regex matching

### Execution Flow
1. **Roles**: Create roles with passwords (if not exists)
2. **Databases**: Create databases with owners (if not exists)
3. **Per-Database**: For each database:
   - Revoke PUBLIC permissions (security hardening)
   - Grant database-level permissions
   - Install extensions
   - Grant schema permissions
   - Grant table permissions (wildcards first, then specific)
   - Set default privileges (with backfill to existing objects)

### Performance
- Single SQL file per provisioning run
- Connection reuse within each database context
- Minimal reconnections (one per database)
- Skip completely when configuration and secrets unchanged

## Expert Review Summary

**Final Score**: 9/10 (Production-Ready)

**Round 5 Consensus** (Gemini 2.5 Pro + GPT-5):
- ✅ All critical security vulnerabilities resolved
- ✅ All functional blockers fixed
- ✅ Implements industry best practices
- ✅ Solid foundation for long-term maintenance
- ✅ Recommended for production deployment

**Key Strengths**:
- Secure password handling via `pg_read_file()`
- Comprehensive pattern matching for identifiers
- Proper SQL injection prevention
- Idempotent design with secret rotation detection
- Excellent architecture with interface/implementation separation

## Contributing

When adding new features:
1. Add options to `database-interface.nix` (API)
2. Implement logic in `databases.nix` (SQL generation)
3. Add tests to verify SQL correctness
4. Update this README with examples
5. Request expert review for security changes

## License

Part of the nix-config repository. See repository root for license.
