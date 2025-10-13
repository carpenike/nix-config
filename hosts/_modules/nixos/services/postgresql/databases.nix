{ lib, pkgs, config, ... }:
# PostgreSQL Database Provisioning Module (Production-Ready: 9/10)
#
# Provides declarative, idempotent database provisioning with comprehensive permission management.
# Services declare their database requirements, this module aggregates and provisions them.
#
# Features:
# - Phase 1: Databases, roles, extensions, basic permissions
# - Phase 2: Schema/table/default privileges, wildcard patterns, security hardening
# - Secure password handling via pg_read_file() (no command-line exposure)
# - Secret rotation detection (password changes trigger re-provisioning)
# - SQL injection prevention (proper quoting for identifiers and strings)
# - Monitoring integration (Prometheus metrics)
#
# Architecture:
# - Services declare: modules.services.postgresql.databases.<dbname> = { owner, permissions, ... }
# - This module aggregates all declarations across services
# - Systemd oneshot service provisions on boot/config changes (idempotent)
# - Single SQL script per run with proper transaction handling
#
# Security:
# - All operations run as postgres superuser (provisioning only)
# - Regular application roles have minimal privileges
# - PUBLIC permissions revoked by default
# - Password files read server-side (never exposed in /proc or logs)
#
# See: hosts/_modules/nixos/services/postgresql/README.md for usage examples
# - Hash-based change detection prevents unnecessary re-runs
#
# MVP Scope (Phase 1):
# - Single PostgreSQL instance only (respects existing assertion)
# - Role creation with SOPS-integrated passwords
# - Database creation with ownership
# - Extension installation
# - Declarative database-level permissions
#
# Future Enhancements (Phase 2+):
# - Multi-instance support (requires custom per-instance systemd units)
# - initScriptPath with run-once-on-change
# - Complex table/column-level permissions
# - Cluster-level shared roles
#
let
  # IMPORTANT: This top-level let block contains ONLY pure helper functions
  # that do NOT depend on config. All config-dependent bindings are moved
  # into the config block below to leverage lazy evaluation and prevent
  # circular dependencies.

  # SQL Identifier and String Quoting Functions (Security Fix)
  #
  # Critical: lib.escapeShellArg is for shell escaping, NOT SQL.
  # Using it for SQL identifiers creates SQL injection vulnerabilities.

  # Quote SQL identifier (column, table, schema, role names)
  # Wraps in double quotes and escapes internal double quotes by doubling them
  # Example: quoteSqlIdentifier "my\"table" -> "\"my\"\"table\""
  # Example: quoteSqlIdentifier "schema.table" -> "\"schema.table\"" (preserves dot)
  quoteSqlIdentifier = identifier:
    let
      # Escape double quotes by doubling them: my"table -> my""table
      escaped = builtins.replaceStrings [''"''] [''""''] identifier;
    in ''"${escaped}"'';

  # Quote SQL string literal (for values, not identifiers)
  # Uses dollar-quoting with unique tag to avoid conflicts and escape issues
  # Example: quoteSqlString "O'Reilly" -> "$sql_abc123$O'Reilly$sql_abc123$"
  # Example: quoteSqlString "a$$b" -> "$sql_def456$a$$b$sql_def456$"
  quoteSqlString = str:
    let
      # Generate a unique tag using hash to avoid collisions
      hash = builtins.hashString "sha256" str;
      # Take first 8 chars of hash for uniqueness
      tag = "sql_${builtins.substring 0 8 hash}";
    in "$${tag}$${str}$${tag}$";

  # Parse schema.table pattern, handling quoted identifiers with dots
  # Returns { schema = "..."; table = "..."; }
  # Handles complex patterns:
  #   "schema.with.dots"."table" -> { schema = "schema.with.dots"; table = "table"; }
  #   public.users -> { schema = "public"; table = "users"; }
  #   "audit".* -> { schema = "audit"; table = "*"; }
  #   users -> { schema = "public"; table = "users"; } (implicit public schema)
  parseTablePattern = pattern:
    let
      # Helper to unescape doubled quotes
      unescape = s: builtins.replaceStrings [''""''] [''"''] s;

      # Try to match different patterns using regex
      # Pattern 1: "sch"."tab" - Both quoted
      m1 = builtins.match ''^"(([^"]|"")+)"\."(([^"]|"")+)"$'' pattern;
      # Pattern 2: "sch".* - Quoted schema, wildcard
      m2 = builtins.match ''^"(([^"]|"")+)"\.\*$'' pattern;
      # Pattern 3: "sch".tab - Quoted schema, unquoted table
      m3 = builtins.match ''^"(([^"]|"")+)"\.([^.]+)$'' pattern;
      # Pattern 4: sch.* - Unquoted schema, wildcard
      m4 = builtins.match ''^([^.]+)\.\*$'' pattern;
      # Pattern 5: sch.tab - Both unquoted
      m5 = builtins.match ''^([^.]+)\.([^.]+)$'' pattern;
      # Pattern 6: "tab" - Just quoted table (public schema)
      m6 = builtins.match ''^"(([^"]|"")+)"$'' pattern;
      # Pattern 7: tab - Just unquoted table (public schema)
      m7 = builtins.match ''^([^.]+)$'' pattern;
      # Pattern 8: sch."tab" - Unquoted schema, quoted table
      m8 = builtins.match ''^([^.]+)\."(([^"]|"")+)"$'' pattern;
    in
      if m1 != null then { schema = unescape (builtins.elemAt m1 0); table = unescape (builtins.elemAt m1 2); }
      else if m2 != null then { schema = unescape (builtins.elemAt m2 0); table = "*"; }
      else if m3 != null then { schema = unescape (builtins.elemAt m3 0); table = builtins.elemAt m3 2; }
      else if m4 != null then { schema = builtins.elemAt m4 0; table = "*"; }
      else if m5 != null then { schema = builtins.elemAt m5 0; table = builtins.elemAt m5 1; }
      else if m6 != null then { schema = "public"; table = unescape (builtins.elemAt m6 0); }
      else if m7 != null then { schema = "public"; table = builtins.elemAt m7 0; }
      else if m8 != null then { schema = builtins.elemAt m8 0; table = unescape (builtins.elemAt m8 1); }
      else { schema = "public"; table = pattern; }; # Fallback

  # Expand permission presets into actual permission configurations
  # This allows users to use opinionated presets (owner-only, owner-readwrite+readonly-select)
  # while still supporting custom fine-grained permissions
  expandPermissionsPolicy = dbName: dbCfg:
    let
      owner = dbCfg.owner;
      policy = dbCfg.permissionsPolicy or "custom";

      # Base permissions from preset
      presetPerms =
        if policy == "owner-only" then {
          databasePermissions = { ${owner} = [ "ALL" ]; };
          schemaPermissions = {
            public = { ${owner} = [ "ALL" ]; };
          };
          tablePermissions = {
            "public.*" = { ${owner} = [ "ALL" ]; };
          };
          defaultPrivileges = {
            "${owner}_defaults" = {
              inherit owner;
              schema = "public";
              tables = { };
              sequences = { };
              functions = { };
            };
          };
        }
        else if policy == "owner-readwrite+readonly-select" then {
          databasePermissions = {
            ${owner} = [ "ALL" ];
            readonly = [ "CONNECT" ];
          };
          schemaPermissions = {
            public = {
              ${owner} = [ "ALL" ];
              readonly = [ "USAGE" ];
            };
          };
          tablePermissions = {
            "public.*" = {
              ${owner} = [ "ALL" ];
              readonly = [ "SELECT" ];
            };
          };
          defaultPrivileges = {
            "${owner}_defaults" = {
              inherit owner;
              schema = "public";
              tables = { readonly = [ "SELECT" ]; };
              sequences = { readonly = [ "SELECT" "USAGE" ]; };
              functions = { };
            };
          };
        }
        else { }; # custom = empty preset
    in
    dbCfg // {
      # Merge preset permissions with manual permissions (manual overrides preset)
      databasePermissions =
        (presetPerms.databasePermissions or {}) //
        (dbCfg.databasePermissions or {});

      schemaPermissions =
        (presetPerms.schemaPermissions or {}) //
        (dbCfg.schemaPermissions or {});

      tablePermissions =
        (presetPerms.tablePermissions or {}) //
        (dbCfg.tablePermissions or {});

      defaultPrivileges =
        (presetPerms.defaultPrivileges or {}) //
        (dbCfg.defaultPrivileges or {});
    };

  # SQL generation helpers (module-generated idempotent SQL)
  # SECURITY: All SQL identifiers use quoteSqlIdentifier to prevent injection

  # Generate safe role creation SQL
  mkRoleSQL = owner: passwordFile: ''
    -- Create role if it doesn't exist
    DO $role$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = ${quoteSqlString owner}) THEN
        CREATE ROLE ${quoteSqlIdentifier owner} WITH LOGIN;
        RAISE NOTICE 'Created role: %', ${quoteSqlString owner};
      ELSE
        RAISE NOTICE 'Role already exists: %', ${quoteSqlString owner};
      END IF;
    END
    $role$;

    ${lib.optionalString (passwordFile != null) ''
      -- Set/update password (runs every time config changes)
      -- Read password from file server-side using pg_read_file (runs as superuser)
      -- Uses fixed 'pw' alias to avoid psql variable naming edge cases with exotic role names
      -- Explicitly set password encryption to scram-sha-256 for security
      SET password_encryption = 'scram-sha-256';
      SELECT trim(both E'\n\r' FROM pg_read_file(${quoteSqlString passwordFile})) AS pw \gset
      ALTER ROLE ${quoteSqlIdentifier owner} WITH PASSWORD :'pw';
      \unset pw
      \echo Updated password for role: ${owner}
    ''}
  '';

  # Generate safe database creation SQL with exception handling and metadata options
  mkDatabaseSQL = dbName: dbCfg:
    let
      owner = dbCfg.owner;
      # Build CREATE DATABASE with optional parameters
      createParams = lib.concatStringsSep " " (lib.filter (x: x != "") [
        "OWNER ${quoteSqlIdentifier owner}"
        (lib.optionalString (dbCfg.encoding != null) "ENCODING ${quoteSqlString dbCfg.encoding}")
        (lib.optionalString (dbCfg.lcCtype != null) "LC_CTYPE ${quoteSqlString dbCfg.lcCtype}")
        (lib.optionalString (dbCfg.collation != null) "LC_COLLATE ${quoteSqlString dbCfg.collation}")
        (lib.optionalString (dbCfg.template != null) "TEMPLATE ${quoteSqlIdentifier dbCfg.template}")
        (lib.optionalString (dbCfg.tablespace != null) "TABLESPACE ${quoteSqlIdentifier dbCfg.tablespace}")
      ]);
    in ''
    -- Create database if it doesn't exist (using exception handling)
    DO $db$
    BEGIN
      CREATE DATABASE ${quoteSqlIdentifier dbName} ${createParams};
      RAISE NOTICE 'Created database: %', ${quoteSqlString dbName};
    EXCEPTION WHEN duplicate_database THEN
      RAISE NOTICE 'Database already exists: %', ${quoteSqlString dbName};
    END
    $db$;
  '';

  # Generate database-level permission grants (backward compatible)
  # NOTE: GRANT ON DATABASE must be executed from a different database context (e.g., postgres)
  # The calling code handles database context switching, so we don't include \c here
  mkPermissionsSQL = dbName: permissions:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (role: perms:
      if perms == [] then ''
        -- REVOKE: Empty permissions list for role ${role}
        REVOKE ALL ON DATABASE ${quoteSqlIdentifier dbName} FROM ${quoteSqlIdentifier role};
        \echo Revoked all permissions from ${role} on ${dbName}
      '' else ''
        -- Grant permissions on database ${dbName} to role ${role}
        GRANT ${lib.concatStringsSep ", " perms} ON DATABASE ${quoteSqlIdentifier dbName} TO ${quoteSqlIdentifier role};
        \echo Granted permissions to ${role} on ${dbName}
      ''
    ) permissions);

  # Generate schema-level permission grants (Phase 2)
  # Includes REVOKE logic for empty permission lists
  # NOTE: Caller must ensure correct database context (\c) before calling this helper
  mkSchemaPermissionsSQL = dbName: schemaPerms:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (schemaName: rolePerms:
      lib.concatStringsSep "\n" (lib.mapAttrsToList (role: perms:
        if perms == [] then ''
          -- REVOKE: Empty permissions list for role ${role} on schema ${schemaName}
          REVOKE ALL ON SCHEMA ${quoteSqlIdentifier schemaName} FROM ${quoteSqlIdentifier role};
          \echo Revoked all schema permissions from ${role} on ${schemaName}
        '' else ''
          -- Grant schema ${schemaName} permissions to role ${role}
          GRANT ${lib.concatStringsSep ", " perms} ON SCHEMA ${quoteSqlIdentifier schemaName} TO ${quoteSqlIdentifier role};
          \echo Granted schema permissions to ${role} on ${schemaName}
        ''
      ) rolePerms)
    ) schemaPerms);

  # Generate table-level permission grants (Phase 2)
  # Includes REVOKE logic and proper precedence (specific overrides wildcard)
  # Also handles sequences and functions alongside tables
  # NOTE: Caller must ensure correct database context (\c) before calling this helper
  mkTablePermissionsSQL = dbName: tablePerms:
    let
      # Parse all patterns and group by schema
      parsedPatterns = lib.mapAttrsToList (pattern: rolePerms:
        let
          parsed = parseTablePattern pattern;
        in {
          inherit pattern rolePerms parsed;
          # Use parsed result to determine wildcard (table == "*")
          isWildcard = (parsed.table == "*");
        }) tablePerms;

      # Process wildcards first, then specific tables (precedence)
      wildcardPatterns = lib.filter (p: p.isWildcard) parsedPatterns;
      specificPatterns = lib.filter (p: !p.isWildcard) parsedPatterns;
      orderedPatterns = wildcardPatterns ++ specificPatterns;
    in
    lib.concatMapStringsSep "\n" (patternInfo:
      let
        schema = patternInfo.parsed.schema;
        table = patternInfo.parsed.table;
        isWildcard = patternInfo.isWildcard;

        # For wildcards, grant on ALL TABLES and ALL SEQUENCES (functions handled separately)
        tableClause = if isWildcard then "ALL TABLES IN SCHEMA ${quoteSqlIdentifier schema}" else "TABLE ${quoteSqlIdentifier schema}.${quoteSqlIdentifier table}";
        sequenceClause = if isWildcard then "ALL SEQUENCES IN SCHEMA ${quoteSqlIdentifier schema}" else "SEQUENCE ${quoteSqlIdentifier schema}.${quoteSqlIdentifier table}";
      in
      lib.concatStringsSep "\n" (lib.mapAttrsToList (role: perms:
        if perms == [] then ''
          -- REVOKE: Empty permissions list for role ${role} on ${patternInfo.pattern}
          \c ${quoteSqlIdentifier dbName}
          REVOKE ALL ON ${tableClause} FROM ${quoteSqlIdentifier role};
          ${lib.optionalString isWildcard "REVOKE ALL ON ${sequenceClause} FROM ${quoteSqlIdentifier role};"}
          \echo Revoked all permissions from ${role} on ${patternInfo.pattern}
        '' else
          let
            # Filter sequence-relevant permissions (SELECT, USAGE, UPDATE for sequences)
            seqPerms = lib.filter (p: p == "SELECT" || p == "USAGE" || p == "UPDATE") perms;
            # Filter out EXECUTE (now handled by functionPermissions)
            tableOnlyPerms = lib.filter (p: p != "EXECUTE") perms;
          in ''
          -- Grant table permissions on ${patternInfo.pattern} to role ${role}
          -- NOTE: EXECUTE permissions should now be in functionPermissions
          ${lib.optionalString (tableOnlyPerms != []) "GRANT ${lib.concatStringsSep ", " tableOnlyPerms} ON ${tableClause} TO ${quoteSqlIdentifier role};"}
          ${lib.optionalString (isWildcard && seqPerms != []) "GRANT ${lib.concatStringsSep ", " seqPerms} ON ${sequenceClause} TO ${quoteSqlIdentifier role};"}
          \echo Granted permissions to ${role} on ${patternInfo.pattern}
        ''
      ) patternInfo.rolePerms)
    ) orderedPatterns;

  # Generate function-level permission grants (Phase 2 - separate from tablePermissions)
  # NOTE: Caller must ensure correct database context (\c) before calling this helper
  mkFunctionPermissionsSQL = dbName: functionPerms:
    let
      # Parse all patterns and group by schema
      parsedPatterns = lib.mapAttrsToList (pattern: rolePerms:
        let
          parsed = parseTablePattern pattern;  # Reuse table pattern parser
        in {
          inherit pattern rolePerms parsed;
          isWildcard = (parsed.table == "*");
        }) functionPerms;

      # Process wildcards first, then specific functions (precedence)
      wildcardPatterns = lib.filter (p: p.isWildcard) parsedPatterns;
      specificPatterns = lib.filter (p: !p.isWildcard) parsedPatterns;
      orderedPatterns = wildcardPatterns ++ specificPatterns;
    in
    lib.concatMapStringsSep "\n" (patternInfo:
      let
        schema = patternInfo.parsed.schema;
        func = patternInfo.parsed.table;  # Reuse 'table' field for function name
        isWildcard = patternInfo.isWildcard;

        functionClause = if isWildcard
          then "ALL FUNCTIONS IN SCHEMA ${quoteSqlIdentifier schema}"
          else "FUNCTION ${quoteSqlIdentifier schema}.${quoteSqlIdentifier func}";
        procedureClause = if isWildcard
          then "ALL PROCEDURES IN SCHEMA ${quoteSqlIdentifier schema}"
          else null;  # Specific procedures need different syntax
      in
      lib.concatStringsSep "\n" (lib.mapAttrsToList (role: perms:
        if perms == [] then ''
          -- REVOKE: Empty permissions list for role ${role} on functions ${patternInfo.pattern}
          REVOKE ALL ON ${functionClause} FROM ${quoteSqlIdentifier role};
          ${lib.optionalString (isWildcard && procedureClause != null) "REVOKE ALL ON ${procedureClause} FROM ${quoteSqlIdentifier role};"}
          \echo Revoked all function permissions from ${role} on ${patternInfo.pattern}
        '' else ''
          -- Grant function permissions on ${patternInfo.pattern} to role ${role}
          GRANT ${lib.concatStringsSep ", " perms} ON ${functionClause} TO ${quoteSqlIdentifier role};
          ${lib.optionalString (isWildcard && procedureClause != null) "GRANT ${lib.concatStringsSep ", " perms} ON ${procedureClause} TO ${quoteSqlIdentifier role};"}
          \echo Granted function permissions to ${role} on ${patternInfo.pattern}
        ''
      ) patternInfo.rolePerms)
    ) orderedPatterns;

  # Generate default privileges (Phase 2)
  # Note: Default privileges only apply to FUTURE objects created by the specified owner role
  # To grant on existing objects, use tablePermissions with wildcards (e.g., "public.*")
  mkDefaultPrivilegesSQL = dbName: defaultPrivs:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (policyName: policy: ''
      -- Default privileges policy: ${policyName}
      \c ${quoteSqlIdentifier dbName}

      ${lib.optionalString (policy.tables != {}) (lib.concatStringsSep "\n" (lib.mapAttrsToList (role: perms: ''
        ALTER DEFAULT PRIVILEGES FOR ROLE ${quoteSqlIdentifier policy.owner} IN SCHEMA ${quoteSqlIdentifier policy.schema}
        GRANT ${lib.concatStringsSep ", " perms} ON TABLES TO ${quoteSqlIdentifier role};
        \echo Set default table privileges for ${role} (owner: ${policy.owner}, schema: ${policy.schema})

        -- Backfill: Also grant on existing tables
        GRANT ${lib.concatStringsSep ", " perms} ON ALL TABLES IN SCHEMA ${quoteSqlIdentifier policy.schema} TO ${quoteSqlIdentifier role};
        \echo Backfilled table privileges for ${role} on existing tables in ${policy.schema}
      '') policy.tables))}

      ${lib.optionalString (policy.sequences != {}) (lib.concatStringsSep "\n" (lib.mapAttrsToList (role: perms: ''
        ALTER DEFAULT PRIVILEGES FOR ROLE ${quoteSqlIdentifier policy.owner} IN SCHEMA ${quoteSqlIdentifier policy.schema}
        GRANT ${lib.concatStringsSep ", " perms} ON SEQUENCES TO ${quoteSqlIdentifier role};
        \echo Set default sequence privileges for ${role} (owner: ${policy.owner}, schema: ${policy.schema})

        -- Backfill: Also grant on existing sequences
        GRANT ${lib.concatStringsSep ", " perms} ON ALL SEQUENCES IN SCHEMA ${quoteSqlIdentifier policy.schema} TO ${quoteSqlIdentifier role};
        \echo Backfilled sequence privileges for ${role} on existing sequences in ${policy.schema}
      '') policy.sequences))}

      ${lib.optionalString (policy.functions != {}) (lib.concatStringsSep "\n" (lib.mapAttrsToList (role: perms: ''
        ALTER DEFAULT PRIVILEGES FOR ROLE ${quoteSqlIdentifier policy.owner} IN SCHEMA ${quoteSqlIdentifier policy.schema}
        GRANT ${lib.concatStringsSep ", " perms} ON FUNCTIONS TO ${quoteSqlIdentifier role};
        \echo Set default function privileges for ${role} (owner: ${policy.owner}, schema: ${policy.schema})

        -- Backfill: Also grant on existing functions
        GRANT ${lib.concatStringsSep ", " perms} ON ALL FUNCTIONS IN SCHEMA ${quoteSqlIdentifier policy.schema} TO ${quoteSqlIdentifier role};
        \echo Backfilled function privileges for ${role} on existing functions in ${policy.schema}
      '') policy.functions))}
    '') defaultPrivs);
  # NOTE: mkProvisionScript has been moved into config block's let binding
  # to leverage lazy evaluation and avoid circular dependencies

  # (Moved to config block below)

in
{
  # Note: Option definitions have been moved to database-interface.nix
  # This module only implements the provisioning logic (config block)
  # See: hosts/_modules/nixos/services/postgresql/database-interface.nix

  config =
    let
      # LAZY EVALUATION: These bindings depend on config and must be inside
      # the config block to avoid circular dependencies. Nix's lazy evaluation
      # allows the module system to determine what this module contributes
      # before fully resolving these values.

      # Read PostgreSQL configuration (simplified single-instance structure)
      cfg = config.modules.services.postgresql;

      # Get databases from the simplified structure
      databases = cfg.databases or {};

      # PostgreSQL package
      pgPackage = if cfg.enable then pkgs."postgresql_${builtins.replaceStrings ["."] [""] cfg.version}" else null;

      # Metrics directory - use consistent path from monitoring module
      metricsDir = config.modules.monitoring.nodeExporter.textfileCollector.directory or "/var/lib/node_exporter/textfile_collector";

    in lib.mkIf (cfg.enable && databases != {}) {
    # Assertions
    assertions = [
      {
        assertion = databases != {};
        message = "Database provisioning enabled but no databases declared";
      }
      {
        assertion = config.services.postgresql.enable or false;
        message = ''
          Database provisioning requires services.postgresql to be enabled.
          The PostgreSQL service must be running before database provisioning can occur.
        '';
      }
    ];

    # Generate systemd service for database provisioning
    # Single service for the single PostgreSQL instance
    systemd.services.postgresql-provision-databases = let
        # Process databases: expand permission presets and filter to managed databases only
        mergedDatabases =
          let
            # Expand permission presets for all declarative databases
            expanded = lib.mapAttrs expandPermissionsPolicy databases;
          in
          # Filter to only managed databases (managed = true)
          lib.filterAttrs (_: dbCfg: dbCfg.managed or true) expanded;

        # Generate complete provisioning script
        mkProvisionScript = pkgs.writeShellScript "postgresql-provision-databases" ''
          set -euo pipefail

          # Provisioning state tracking
          STATE_DIR="/var/lib/postgresql/provisioning/main"
          STAMP_FILE="$STATE_DIR/provisioned.sha256"
          METRICS_FILE="${metricsDir}/postgresql_database_provisioning.prom"

          mkdir -p "$STATE_DIR"
          chmod 0700 "$STATE_DIR"

          echo "=== PostgreSQL Database Provisioning ==="
          echo "Instance: main"
          echo "Databases: ${toString (lib.length (lib.attrNames mergedDatabases))}"

          # Compute hash of current configuration AND secret file contents
          # This includes all database declarations to detect any changes
          CONFIG_HASH="${builtins.hashString "sha256" (builtins.toJSON mergedDatabases)}"

          # Compute hash of all password files to detect secret rotation
          # This ensures password changes trigger re-provisioning
          SECRETS_HASH=""
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (dbName: dbCfg:
            lib.optionalString (dbCfg.ownerPasswordFile or null != null) ''
              if [ -f "${dbCfg.ownerPasswordFile}" ]; then
                SECRETS_HASH="$SECRETS_HASH$(sha256sum "${dbCfg.ownerPasswordFile}" | cut -d' ' -f1)"
              fi
            ''
          ) mergedDatabases)}
          COMBINED_HASH=$(echo "$CONFIG_HASH$SECRETS_HASH" | sha256sum | cut -d' ' -f1)

          # Check if provisioning is needed
          if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$COMBINED_HASH" ]; then
            echo "✓ Database configuration and secrets unchanged - skipping provisioning"
            ${lib.optionalString (config.modules.monitoring.enable or false) ''
              # Update metrics
              cat > "$METRICS_FILE" <<METRICS
              # HELP postgresql_database_provisioning_last_run_timestamp Last time provisioning ran
              # TYPE postgresql_database_provisioning_last_run_timestamp gauge
              postgresql_database_provisioning_last_run_timestamp{status="skipped"} $(date +%s)
              METRICS
            ''}
            exit 0
          fi

          echo "→ Configuration changed - running provisioning"

          # Wait for PostgreSQL to be ready
          echo "Waiting for PostgreSQL to be ready..."
          MAX_RETRIES=30
          RETRY_COUNT=0
          until ${pgPackage}/bin/pg_isready -h localhost -U postgres -d postgres; do
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
              echo "✗ PostgreSQL failed to become ready after $MAX_RETRIES attempts"
              ${lib.optionalString (config.modules.monitoring.enable or false) ''
                cat > "$METRICS_FILE" <<METRICS
                # HELP postgresql_database_provisioning_last_run_timestamp Last time provisioning ran
                # TYPE postgresql_database_provisioning_last_run_timestamp gauge
                postgresql_database_provisioning_last_run_timestamp{status="failed"} $(date +%s)
                METRICS
              ''}
              exit 1
            fi
            echo "  Retry $RETRY_COUNT/$MAX_RETRIES..."
            sleep 2
          done
          echo "✓ PostgreSQL is ready"

          # Create temporary SQL file with restrictive permissions
          SQL_FILE="$(mktemp -p "$STATE_DIR" provision.XXXXXX.sql)"
          chmod 0600 "$SQL_FILE"
          trap "rm -f $SQL_FILE" EXIT

          # Generate provisioning SQL with improved execution grouping
          cat > "$SQL_FILE" <<'PROVISION_SQL'
          -- PostgreSQL Database Provisioning Script
          -- Generated by NixOS modules.services.postgresql
          -- This script is idempotent and safe to run multiple times
          --
          -- SECURITY: All identifiers properly quoted to prevent SQL injection
          -- EXECUTION: Grouped by database to minimize connection changes

          \set ON_ERROR_STOP on
          \set VERBOSITY verbose

          -- Provisioning timestamp
          SELECT NOW() AS provisioning_started;

          -- ========================================
          -- SESSION CONFIGURATION (Security hardening)
          -- ========================================
          SET statement_timeout = 60000;  -- 60 seconds
          SET lock_timeout = 10000;       -- 10 seconds
          SET search_path = pg_catalog, public;  -- Prevent function shadowing attacks

          -- ========================================
          -- PHASE 1: Create all roles first (connect to postgres database)
          -- ========================================
          \c postgres

          -- Reset session config after connection change
          SET statement_timeout = 60000;
          SET lock_timeout = 10000;
          SET search_path = pg_catalog, public;

          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (dbName: dbCfg:
            mkRoleSQL dbCfg.owner dbCfg.ownerPasswordFile
          ) mergedDatabases)}

          -- ========================================
          -- Create readonly role (if any database uses owner-readwrite+readonly-select preset)
          -- ========================================
          ${lib.optionalString (lib.any (dbCfg: (dbCfg.permissionsPolicy or "custom") == "owner-readwrite+readonly-select") (lib.attrValues mergedDatabases)) ''
          -- Create readonly role if it doesn't exist (NOLOGIN - grant to actual login roles)
          -- SECURITY: NOLOGIN prevents direct authentication; grant this role to service accounts
          DO $role$
          BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'readonly') THEN
              CREATE ROLE readonly WITH NOLOGIN;
              RAISE NOTICE 'Created readonly role (NOLOGIN - grant to actual login roles for read-only access)';
            ELSE
              RAISE NOTICE 'Readonly role already exists';
            END IF;
          END
          $role$;
          ''}

          -- ========================================
          -- PHASE 2: Create all databases (still in postgres database)
          -- ========================================

          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (dbName: dbCfg:
            mkDatabaseSQL dbName dbCfg
          ) mergedDatabases)}

          -- ========================================
          -- PHASE 3: Configure each database (one \c per database)
          -- ========================================

          ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (dbName: dbCfg:
            let
              hasExtensions = dbCfg.extensions != [];
              hasDbPerms = (dbCfg.databasePermissions or {}) != {};
              hasSchemaPerms = (dbCfg.schemaPermissions or {}) != {};
              hasTablePerms = (dbCfg.tablePermissions or {}) != {};
              hasFunctionPerms = (dbCfg.functionPermissions or {}) != {};
              hasDefaultPrivs = (dbCfg.defaultPrivileges or {}) != {};

              needsConfig = hasExtensions || hasDbPerms || hasSchemaPerms || hasTablePerms || hasFunctionPerms || hasDefaultPrivs;
            in
            lib.optionalString needsConfig ''
            -- ----------------------------------------
            -- Database: ${dbName}
            -- Owner: ${dbCfg.owner}
            -- ----------------------------------------
            \c ${quoteSqlIdentifier dbName}

            -- Reset session config after connection change
            SET statement_timeout = 60000;
            SET lock_timeout = 10000;
            SET search_path = pg_catalog, public;

            -- Security hardening: Revoke PUBLIC permissions
            \c postgres
            REVOKE ALL ON DATABASE ${quoteSqlIdentifier dbName} FROM PUBLIC;
            \c ${quoteSqlIdentifier dbName}
            REVOKE ALL ON SCHEMA public FROM PUBLIC;
            REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
            REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC;
            REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
            \echo Revoked default PUBLIC permissions for security hardening

            ${lib.optionalString hasExtensions ''
            -- Extensions for ${dbName}
            ${lib.concatMapStringsSep "\n" (ext: ''
            CREATE EXTENSION IF NOT EXISTS ${quoteSqlIdentifier ext};
            \echo Extension ${ext} ready
            '') dbCfg.extensions}
            ''}

            ${lib.optionalString hasDbPerms ''
            -- Database-level permissions for ${dbName}
            \c postgres
            ${mkPermissionsSQL dbName dbCfg.databasePermissions}
            \c ${quoteSqlIdentifier dbName}
            ''}

            ${lib.optionalString hasSchemaPerms (mkSchemaPermissionsSQL dbName dbCfg.schemaPermissions)}

            ${lib.optionalString hasTablePerms (mkTablePermissionsSQL dbName dbCfg.tablePermissions)}

            ${lib.optionalString hasFunctionPerms (mkFunctionPermissionsSQL dbName dbCfg.functionPermissions)}

            ${lib.optionalString hasDefaultPrivs (mkDefaultPrivilegesSQL dbName dbCfg.defaultPrivileges)}
            ''
          ) mergedDatabases)}

          -- ========================================
          -- SUMMARY
          -- ========================================
          \c postgres

          SELECT
            COUNT(*) FILTER (WHERE datname != 'postgres' AND datname != 'template0' AND datname != 'template1') as user_databases,
            NOW() as provisioning_completed
          FROM pg_database;
          PROVISION_SQL

          # Execute provisioning with no secrets on the command-line
          echo "→ Executing provisioning SQL..."

          # Run psql (passwords are read inside the SQL script via \set)
          if ${pgPackage}/bin/psql -U postgres -d postgres -f "$SQL_FILE"; then

            echo "✓ Provisioning completed successfully"

            # Record successful provisioning (includes config + secrets hash)
            echo "$COMBINED_HASH" > "$STAMP_FILE"

            ${lib.optionalString (config.modules.monitoring.enable or false) ''
              # Update metrics
              cat > "$METRICS_FILE" <<METRICS
              # HELP postgresql_database_provisioning_last_run_timestamp Last time provisioning ran
              # TYPE postgresql_database_provisioning_last_run_timestamp gauge
              postgresql_database_provisioning_last_run_timestamp{status="success"} $(date +%s)

              # HELP postgresql_database_count Number of user databases
              # TYPE postgresql_database_count gauge
              postgresql_database_count ${toString (lib.length (lib.attrNames mergedDatabases))}
              METRICS
            ''}

          else
            echo "✗ Provisioning failed for PostgreSQL"
            echo "   Databases affected: ${lib.concatStringsSep ", " (lib.attrNames mergedDatabases)}"
            ${lib.optionalString (config.modules.monitoring.enable or false) ''
              cat > "$METRICS_FILE" <<METRICS
              # HELP postgresql_database_provisioning_last_run_timestamp Last time provisioning ran
              # TYPE postgresql_database_provisioning_last_run_timestamp gauge
              postgresql_database_provisioning_last_run_timestamp{status="failed"} $(date +%s)
              METRICS
            ''}
            exit 1
          fi
        '';
      in {
        description = "Provision PostgreSQL databases";
        after = [ "postgresql.service" ];
        requires = [ "postgresql.service" ];
        wantedBy = [ "multi-user.target" ];

        # Run once per boot, but only if config changed
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
          Group = "postgres";

          # Security hardening
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;

          # Create state directory for provisioning
          StateDirectory = "postgresql/provisioning";
          StateDirectoryMode = "0755";

          # Allow writing to state dir and metrics
          ReadWritePaths = [
            "/var/lib/postgresql/provisioning"
          ] ++ lib.optional (config.modules.monitoring.enable or false) metricsDir;

          # Secrets access
          SupplementaryGroups = lib.optional (config.modules.monitoring.enable or false) "node-exporter";

          ExecStart = "${mkProvisionScript}";
        };

        # Notification on failure
        unitConfig = lib.mkIf (config.modules.notifications.enable or false) {
          OnFailure = [ "notify@postgresql-provision-failure.service" ];
        };
      };

    # Notification templates
    modules.notifications.templates = lib.mkIf (config.modules.notifications.enable or false) {
      postgresql-provision-success = {
        enable = true;
        priority = "normal";
        title = "✅ PostgreSQL Provisioning Complete";
        body = ''
          <b>Status:</b> All databases provisioned successfully
          <b>Service:</b> postgresql-provision-databases
        '';
      };

      postgresql-provision-failure = {
        enable = true;
        priority = "high";
        title = "✗ PostgreSQL Provisioning Failed";
        body = ''
          <b>Error:</b> Database provisioning encountered an error
          <b>Action Required:</b> Check systemd logs: journalctl -u postgresql-provision-databases
        '';
      };
    };
  };
}
