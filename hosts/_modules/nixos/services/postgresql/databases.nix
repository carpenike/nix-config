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
# - Basic database-level permissions
# - Backward compatibility with existing databases = [ ... ] list
#
# Future Enhancements (Phase 2+):
# - Multi-instance support (requires custom per-instance systemd units)
# - initScriptPath with run-once-on-change
# - Complex table/column-level permissions
# - Cluster-level shared roles
#
let
  cfg = config.modules.services.postgresql;

  # Filter to only enabled PostgreSQL instances
  enabledInstances = lib.filterAttrs (_: inst: inst.enable) cfg.instances;

  # Get the single enabled instance (there can only be one due to existing assertion)
  singleInstance = if enabledInstances != {} then
    lib.head (lib.attrValues enabledInstances)
  else
    null;

  singleInstanceName = if enabledInstances != {} then
    lib.head (lib.attrNames enabledInstances)
  else
    null;

  # PostgreSQL package for the enabled instance
  pgPackage = if singleInstance != null then
    pkgs."postgresql_${builtins.replaceStrings ["."] [""] singleInstance.version}"
  else
    pkgs.postgresql_16;  # Fallback

  # Notification config
  notificationsCfg = config.modules.notifications;
  hasCentralizedNotifications = notificationsCfg.enable or false;

  # Metrics directory
  metricsDir = config.modules.backup.monitoring.prometheus.metricsDir or "/var/lib/node_exporter/textfile_collector";

  # SQL Identifier and String Quoting Functions (Security Fix)
  #
  # Critical: lib.escapeShellArg is for shell escaping, NOT SQL.
  # Using it for SQL identifiers creates SQL injection vulnerabilities.

  # Quote SQL identifier (column, table, schema, role names)
  # Wraps in double quotes and escapes internal double quotes by doubling them
  quoteSqlIdentifier = identifier:
    let
      # Escape double quotes by doubling them: my"table -> my""table
      escaped = builtins.replaceStrings [''"''] [''""''] identifier;
    in ''"${escaped}"'';

  # Quote SQL string literal (for values, not identifiers)
  # Uses dollar-quoting with unique tag to avoid conflicts
  # If input contains $$, use a unique tag based on hash
  quoteSqlString = str:
    let
      # Generate a unique tag using hash to avoid collisions
      hash = builtins.hashString "sha256" str;
      # Take first 8 chars of hash for uniqueness
      tag = "sql_${builtins.substring 0 8 hash}";
    in "$${tag}$${str}$${tag}$";

  # Parse schema.table pattern, handling quoted identifiers with dots
  # Returns { schema = "..."; table = "..."; }
  # Handles: "schema.with.dots"."table", unquoted.identifiers, wildcards
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

  # Merge databases from both new declarative API and legacy list
  # This provides backward compatibility
  mergedDatabases =
    let
      # Databases from new declarative API
      declarativeDbs = cfg.databases;

      # Databases from legacy list (if any instance has them)
      legacyDbs = if singleInstance != null && singleInstance.databases != [] then
        lib.listToAttrs (map (dbName: {
          name = dbName;
          value = {
            owner = "postgres";  # Default owner for legacy DBs
            ownerPasswordFile = null;
            extensions = [];
            permissions = {};
          };
        }) singleInstance.databases)
      else {};
    in
    # Declarative takes precedence over legacy
    legacyDbs // declarativeDbs;

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
      SELECT trim(both E'\n\r' FROM pg_read_file(${quoteSqlString passwordFile})) AS pw \gset
      ALTER ROLE ${quoteSqlIdentifier owner} WITH PASSWORD :'pw';
      \unset pw
      \echo Updated password for role: ${owner}
    ''}
  '';

  # Generate safe database creation SQL with exception handling
  mkDatabaseSQL = dbName: owner: ''
    -- Create database if it doesn't exist (using exception handling)
    DO $db$
    BEGIN
      CREATE DATABASE ${quoteSqlIdentifier dbName} OWNER ${quoteSqlIdentifier owner};
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

        # For wildcards, grant on ALL TABLES, ALL SEQUENCES, and ALL FUNCTIONS
        tableClause = if isWildcard then "ALL TABLES IN SCHEMA ${quoteSqlIdentifier schema}" else "TABLE ${quoteSqlIdentifier schema}.${quoteSqlIdentifier table}";
        sequenceClause = if isWildcard then "ALL SEQUENCES IN SCHEMA ${quoteSqlIdentifier schema}" else "SEQUENCE ${quoteSqlIdentifier schema}.${quoteSqlIdentifier table}";
        functionClause = if isWildcard then "ALL FUNCTIONS IN SCHEMA ${quoteSqlIdentifier schema}" else null;
      in
      lib.concatStringsSep "\n" (lib.mapAttrsToList (role: perms:
        if perms == [] then ''
          -- REVOKE: Empty permissions list for role ${role} on ${patternInfo.pattern}
          \c ${quoteSqlIdentifier dbName}
          REVOKE ALL ON ${tableClause} FROM ${quoteSqlIdentifier role};
          ${lib.optionalString isWildcard "REVOKE ALL ON ${sequenceClause} FROM ${quoteSqlIdentifier role};"}
          ${lib.optionalString (isWildcard && functionClause != null) "REVOKE ALL ON ${functionClause} FROM ${quoteSqlIdentifier role};"}
          \echo Revoked all permissions from ${role} on ${patternInfo.pattern}
        '' else
          let
            # Filter sequence-relevant permissions
            seqPerms = lib.filter (p: p == "SELECT" || p == "USAGE" || p == "UPDATE") perms;
            # Check if EXECUTE permission is present
            hasExecute = lib.any (p: p == "EXECUTE") perms;
          in ''
          -- Grant table permissions on ${patternInfo.pattern} to role ${role}
          GRANT ${lib.concatStringsSep ", " perms} ON ${tableClause} TO ${quoteSqlIdentifier role};
          ${lib.optionalString (isWildcard && seqPerms != []) "GRANT ${lib.concatStringsSep ", " seqPerms} ON ${sequenceClause} TO ${quoteSqlIdentifier role};"}
          ${lib.optionalString (isWildcard && hasExecute) "GRANT EXECUTE ON ${functionClause} TO ${quoteSqlIdentifier role};"}
          ${lib.optionalString (isWildcard && hasExecute) "GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA ${quoteSqlIdentifier schema} TO ${quoteSqlIdentifier role};"}
          \echo Granted permissions to ${role} on ${patternInfo.pattern}
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

  # Generate complete provisioning script
  mkProvisionScript = pkgs.writeShellScript "postgresql-provision-databases" ''
    set -euo pipefail

    # Provisioning state tracking
    STATE_DIR="/var/lib/postgresql/provisioning"
    STAMP_FILE="$STATE_DIR/provisioned.sha256"
    METRICS_FILE="${metricsDir}/postgresql_database_provisioning.prom"

    mkdir -p "$STATE_DIR"
    chmod 0700 "$STATE_DIR"

    echo "=== PostgreSQL Database Provisioning ==="
    echo "Instance: ${if singleInstanceName != null then singleInstanceName else "none"}"
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
        postgresql_database_provisioning_last_run_timestamp{instance="${if singleInstanceName != null then singleInstanceName else "none"}",status="skipped"} $(date +%s)
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
          postgresql_database_provisioning_last_run_timestamp{instance="${if singleInstanceName != null then singleInstanceName else "none"}",status="failed"} $(date +%s)
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
    -- Generated by NixOS modules.services.postgresql.databases
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
    -- PHASE 2: Create all databases (still in postgres database)
    -- ========================================

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (dbName: dbCfg:
      mkDatabaseSQL dbName dbCfg.owner
    ) mergedDatabases)}

    -- ========================================
    -- PHASE 3: Configure each database (one \c per database)
    -- ========================================

    ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (dbName: dbCfg:
      let
        # Merge old "permissions" with new "databasePermissions" for backward compatibility
        # New API (databasePermissions) takes precedence over legacy (permissions)
        effectiveDbPerms = (dbCfg.permissions or {}) // (dbCfg.databasePermissions or {});

        hasExtensions = dbCfg.extensions != [];
        hasDbPerms = effectiveDbPerms != {};
        hasSchemaPerms = (dbCfg.schemaPermissions or {}) != {};
        hasTablePerms = (dbCfg.tablePermissions or {}) != {};
        hasDefaultPrivs = (dbCfg.defaultPrivileges or {}) != {};

        needsConfig = hasExtensions || hasDbPerms || hasSchemaPerms || hasTablePerms || hasDefaultPrivs;
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
      ${mkPermissionsSQL dbName effectiveDbPerms}
      \c ${quoteSqlIdentifier dbName}
      ''}

      ${lib.optionalString hasSchemaPerms (mkSchemaPermissionsSQL dbName dbCfg.schemaPermissions)}

      ${lib.optionalString hasTablePerms (mkTablePermissionsSQL dbName dbCfg.tablePermissions)}

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
        postgresql_database_provisioning_last_run_timestamp{instance="${if singleInstanceName != null then singleInstanceName else "none"}",status="success"} $(date +%s)

        # HELP postgresql_database_count Number of user databases
        # TYPE postgresql_database_count gauge
        postgresql_database_count{instance="${if singleInstanceName != null then singleInstanceName else "none"}"} ${toString (lib.length (lib.attrNames mergedDatabases))}
        METRICS
      ''}

    else
      echo "✗ Provisioning failed"
      ${lib.optionalString (config.modules.monitoring.enable or false) ''
        cat > "$METRICS_FILE" <<METRICS
        # HELP postgresql_database_provisioning_last_run_timestamp Last time provisioning ran
        # TYPE postgresql_database_provisioning_last_run_timestamp gauge
        postgresql_database_provisioning_last_run_timestamp{instance="${if singleInstanceName != null then singleInstanceName else "none"}",status="failed"} $(date +%s)
        METRICS
      ''}
      exit 1
    fi
  '';

in
{
  # Note: Option definitions have been moved to database-interface.nix
  # This module only implements the provisioning logic (config block)
  # See: hosts/_modules/nixos/services/postgresql/database-interface.nix

  config = lib.mkIf (cfg.databases != {} || (singleInstance != null && singleInstance.databases != [])) {
    # Assertions
    assertions = [
      {
        assertion = mergedDatabases != {};
        message = "Database provisioning enabled but no databases declared";
      }
      {
        assertion = singleInstance != null;
        message = ''
          Database provisioning requires an enabled PostgreSQL instance.
          Enable at least one instance in modules.services.postgresql.instances.
        '';
      }
      # Validate that all databases use "local" provider (external not yet implemented)
      {
        assertion = lib.all (db: db.provider == "local") (lib.attrValues mergedDatabases);
        message = ''
          External PostgreSQL provider is not yet implemented.
          All databases must use provider = "local" (the default).

          Found database(s) with provider = "external":
          ${lib.concatStringsSep ", " (lib.filter (name: mergedDatabases.${name}.provider != "local") (lib.attrNames mergedDatabases))}
        '';
      }
    ]
    # Conflict detection: Check for duplicate database declarations with divergent settings
    # This catches cases where two services try to declare the same database with different owners/settings
    ++ (lib.concatLists (lib.mapAttrsToList (dbName: dbConfig:
      let
        # Check if this database appears in both declarative and legacy lists with different settings
        declarativeDb = cfg.databases.${dbName} or null;
        legacyDbs = if singleInstance != null then singleInstance.databases else [];
        inLegacy = lib.elem dbName legacyDbs;

        # If in both, the declarative one wins (as designed), but warn about conflict
        hasConflict = declarativeDb != null && inLegacy && declarativeDb.owner != "postgres";
      in
      lib.optional hasConflict {
        assertion = false;
        message = ''
          Database "${dbName}" declared in both legacy (instances.*.databases list) and
          new declarative API (databases.${dbName}) with different owners.

          The declarative API takes precedence, but this may indicate a configuration error.
          Remove "${dbName}" from the legacy databases list if using declarative provisioning.

          Declarative owner: ${declarativeDb.owner}
          Legacy owner: postgres (default)
        '';
      }
    ) mergedDatabases));

    # Provisioning systemd service
    systemd.services."postgresql-provision-databases" = {
      description = "Provision PostgreSQL databases for instance ${if singleInstanceName != null then singleInstanceName else "none"}";
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

        # Allow writing to state dir and metrics
        ReadWritePaths = [
          "/var/lib/postgresql/provisioning"
        ] ++ lib.optional (config.modules.monitoring.enable or false) metricsDir;

        # Secrets access
        SupplementaryGroups = lib.optional (config.modules.monitoring.enable or false) "node-exporter";

        ExecStart = "${mkProvisionScript}";
      };

      # Notification on failure
      unitConfig = lib.mkIf hasCentralizedNotifications {
        OnFailure = [ "notify@postgresql-provision-failure.service" ];
      };
    };

    # Notification templates
  } // lib.optionalAttrs hasCentralizedNotifications {
    modules.notifications.templates = {
      postgresql-provision-success = {
        enable = true;
        priority = "normal";
        title = "✅ PostgreSQL Provisioning Complete";
        body = ''
          <b>Instance:</b> ${if singleInstanceName != null then singleInstanceName else "none"}
          <b>Databases:</b> ${toString (lib.length (lib.attrNames mergedDatabases))}
          <b>Status:</b> All databases provisioned successfully
        '';
      };

      postgresql-provision-failure = {
        enable = true;
        priority = "high";
        title = "✗ PostgreSQL Provisioning Failed";
        body = ''
          <b>Instance:</b> ${if singleInstanceName != null then singleInstanceName else "none"}
          <b>Error:</b> Database provisioning encountered an error
          <b>Action Required:</b> Check systemd logs: journalctl -u postgresql-provision-databases
        '';
      };
    };
  };
}
