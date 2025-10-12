{ lib, ... }:
# PostgreSQL Database Interface Module
#
# This module declares the `modules.services.postgresql.databases` option
# globally, allowing service modules to declare their database requirements
# even on hosts that don't have PostgreSQL installed.
#
# This follows the NixOS best practice of separating "interface" (option declaration)
# from "implementation" (actual provisioning), preventing evaluation errors
# when modules reference options that may not exist.
#
# Architecture Pattern (per GPT-5 and Gemini Pro consensus review):
# - This interface module is imported by ALL hosts
# - Service modules can safely write to databases.* on any host
# - The databases.nix implementation module only runs on hosts with PostgreSQL
# - Hosts without PostgreSQL simply have an empty databases attrset
#
# PHASE 1 SCOPE (Implemented):
# - Database-level permissions (CONNECT, CREATE, TEMP, ALL)
# - Basic role and database creation
# - Extension installation
#
# PHASE 2 SCOPE (Implemented):
# - Schema-level permissions (USAGE, CREATE on schemas)
# - Table-level permissions (SELECT, INSERT, UPDATE, DELETE on tables/sequences)
# - Default privileges (ALTER DEFAULT PRIVILEGES for future objects)
# - Per-schema and per-table granular access control
# - Database metadata (encoding, locale, template, tablespace)
# - Provider abstraction (local/external PostgreSQL)
{
  options.modules.services.postgresql.databases = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        owner = lib.mkOption {
          type = lib.types.str;
          description = "Database owner role name";
        };

        ownerPasswordFile = lib.mkOption {
          type = lib.types.str;
          apply = p:
            assert lib.assertMsg
              (!lib.hasPrefix "/nix/store" p)
              "ownerPasswordFile must not be in the Nix store (would leak secrets). Use a runtime path like /run/secrets/...";
            p;
          description = ''
            Runtime path to file containing the database owner's password.
            Must be a runtime path (e.g., /run/secrets/..., /run/agenix/...)
            that is NOT copied to the Nix store.

            SECURITY: Never use a literal path that would be copied to /nix/store.
            Use SOPS, agenix, or systemd LoadCredential for secret management.
          '';
          example = "/run/secrets/myapp/db_password";
        };

        extensions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = ''
            List of PostgreSQL extensions to enable for this database.
            Extension names are validated at runtime against available extensions.

            Common extensions: pg_trgm, btree_gin, btree_gist, pgcrypto, uuid-ossp, hstore
          '';
          example = [ "pg_trgm" "btree_gin" ];
        };

        # Permission preset for common patterns
        permissionsPolicy = lib.mkOption {
          type = lib.types.enum [ "owner-only" "owner-readwrite+readonly-select" "custom" ];
          default = "custom";
          description = ''
            Opinionated permission presets for common use cases. Simplifies configuration
            by automatically generating schema, table, and default privilege grants.

            - owner-only: Only the database owner has access (most restrictive)
            - owner-readwrite+readonly-select: Owner has full access, creates a 'readonly'
              role with SELECT on all tables/sequences in public schema
            - custom: Use manual databasePermissions, schemaPermissions, tablePermissions

            When using a preset, the following permissions are auto-generated:
            - Database-level: CONNECT, CREATE, TEMP for owner (and readonly if applicable)
            - Schema-level: USAGE, CREATE for owner (USAGE only for readonly)
            - Table-level: ALL for owner (SELECT for readonly on public.*)
            - Default privileges: Automatic grants for future objects

            NOTE: Presets can be combined with manual permissions. The preset generates
            base permissions, and you can add additional grants via the manual options.
          '';
          example = "owner-readwrite+readonly-select";
        };

        # Database metadata options
        encoding = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Database encoding (default: UTF8)";
          example = "UTF8";
        };

        lcCtype = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            LC_CTYPE locale setting for character classification (default: cluster default).
            This determines character classification: which characters are letters, digits, etc.
          '';
          example = "en_US.UTF-8";
        };

        collation = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            LC_COLLATE locale setting for string sorting (default: cluster default).
            This determines the sort order for strings.
          '';
          example = "en_US.UTF-8";
        };

        template = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Template database to copy from (default: template1)";
          example = "template0";
        };

        tablespace = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Tablespace to use for this database";
          example = "fast_ssd";
        };

        managed = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Whether this database is managed by the provisioning system.
            If false, the database is expected to exist but won't be created or modified.
          '';
        };

        # Provider abstraction for remote PostgreSQL
        provider = lib.mkOption {
          type = lib.types.enum [ "local" "external" ];
          default = "local";
          description = ''
            Database provider type:
            - local: PostgreSQL instance on this host (fully implemented)
            - external: Remote PostgreSQL server (NOT YET IMPLEMENTED - will be rejected at runtime)

            NOTE: Currently only "local" provider is supported. Setting "external" will
            cause the provisioning service to fail with a clear error message.
          '';
        };

        externalConfig = lib.mkOption {
          type = lib.types.nullOr (lib.types.submodule {
            options = {
              host = lib.mkOption {
                type = lib.types.str;
                description = "External PostgreSQL host";
              };

              port = lib.mkOption {
                type = lib.types.port;
                default = 5432;
                description = "External PostgreSQL port";
              };

              adminUser = lib.mkOption {
                type = lib.types.str;
                default = "postgres";
                description = "Admin user for provisioning";
              };

              adminPasswordFile = lib.mkOption {
                type = lib.types.str;
                description = "Path to admin password file";
              };

              sslMode = lib.mkOption {
                type = lib.types.enum [ "disable" "allow" "prefer" "require" "verify-ca" "verify-full" ];
                default = "verify-full";
                description = ''
                  SSL mode for connection. SECURITY: Use verify-full for production.

                  - disable: No SSL (insecure, not recommended)
                  - allow: Try non-SSL first, then SSL if required
                  - prefer: Try SSL first, fall back to non-SSL
                  - require: Require SSL, but don't verify certificate (vulnerable to MITM)
                  - verify-ca: Require SSL and verify CA (better)
                  - verify-full: Require SSL and verify hostname matches certificate (recommended)
                '';
              };

              sslRootCert = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Path to SSL root certificate for verify-ca or verify-full modes.
                  Required when sslMode is verify-ca or verify-full.
                '';
                example = "/etc/ssl/certs/ca-bundle.crt";
              };

              statementTimeout = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = 60000;  # 60 seconds
                description = ''
                  Statement timeout in milliseconds. Prevents runaway queries.
                  Set to 0 to disable timeout (not recommended).
                '';
              };

              lockTimeout = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = 10000;  # 10 seconds
                description = ''
                  Lock acquisition timeout in milliseconds. Prevents deadlocks.
                  Set to 0 to disable timeout (not recommended).
                '';
              };
            };
          });
          default = null;
          description = "Configuration for external PostgreSQL provider";
        };

        # Database-level permissions
        databasePermissions = lib.mkOption {
          type = lib.types.attrsOf (lib.types.listOf (lib.types.enum [
            "ALL"       # All database-level privileges
            "CONNECT"   # Allow connections to the database
            "CREATE"    # Allow creating schemas in the database
            "TEMP"      # Allow creating temporary tables
            "TEMPORARY" # Alias for TEMP
          ]));
          default = {};
          description = ''
            Database-level permissions to grant to additional roles.

            Valid PostgreSQL database privileges:
            - ALL: All database-level privileges (CONNECT + CREATE + TEMP)
            - CONNECT: Allow connections to this database
            - CREATE: Allow creating new schemas in this database
            - TEMP/TEMPORARY: Allow creating temporary tables
          '';
          example = {
            myapp = [ "ALL" ];
            monitoring = [ "CONNECT" ];
          };
        };

        # Schema-level permissions (Phase 2)
        schemaPermissions = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf (lib.types.enum [
            "ALL"      # All schema privileges
            "USAGE"    # Allow using objects in schema
            "CREATE"   # Allow creating objects in schema
          ])));
          default = {};
          description = ''
            Schema-level permissions to grant to roles.
            Structure: { schema_name = { role_name = [ privileges ]; }; }

            Valid PostgreSQL schema privileges:
            - ALL: All schema privileges (USAGE + CREATE)
            - USAGE: Allow using objects in the schema (required for SELECT/INSERT/etc)
            - CREATE: Allow creating new objects in the schema
          '';
          example = {
            public = {
              readonly = [ "USAGE" ];
              myapp = [ "ALL" ];
            };
            private = {
              myapp = [ "ALL" ];
            };
          };
        };

        # Table-level permissions (Phase 2)
        tablePermissions = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf (lib.types.enum [
            "ALL"       # All table privileges
            "SELECT"    # Read data
            "INSERT"    # Insert data
            "UPDATE"    # Update data
            "DELETE"    # Delete data
            "TRUNCATE"  # Truncate table
            "REFERENCES"# Create foreign keys
            "TRIGGER"   # Create triggers
            "EXECUTE"   # Execute functions/procedures (applies when using wildcards)
          ])));
          default = {};
          description = ''
            Table-level permissions to grant to roles.
            Structure: { schema_name.table_pattern = { role_name = [ privileges ]; }; }

            Use "*" as table_pattern to match all tables in a schema.
            Use specific table names for granular control.

            Valid PostgreSQL table privileges:
            - ALL: All table privileges
            - SELECT: Read data from tables
            - INSERT: Insert new rows
            - UPDATE: Modify existing rows
            - DELETE: Remove rows
            - TRUNCATE: Empty tables
            - REFERENCES: Create foreign key constraints
            - TRIGGER: Create triggers
            - EXECUTE: Execute functions/procedures (only valid with wildcard patterns like "public.*")
          '';
          example = {
            "public.*" = {
              readonly = [ "SELECT" ];
              myapp = [ "ALL" ];
            };
            "public.sensitive_table" = {
              readonly = [ ];  # No access
              myapp = [ "SELECT" "UPDATE" ];
            };
          };
        };

        # Function-level permissions (Phase 2 - separated from tablePermissions)
        functionPermissions = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf (lib.types.enum [
            "ALL"       # All function privileges
            "EXECUTE"   # Execute functions/procedures
          ])));
          default = {};
          description = ''
            Function-level permissions to grant to roles.
            Structure: { schema_name.function_pattern = { role_name = [ privileges ]; }; }

            Use "*" as function_pattern to match all functions in a schema.
            Use specific function names for granular control.

            Valid PostgreSQL function privileges:
            - ALL: All function privileges (just EXECUTE currently)
            - EXECUTE: Execute functions and procedures

            NOTE: This is separate from tablePermissions for clarity. Previously,
            EXECUTE was handled implicitly in tablePermissions with wildcards.
          '';
          example = {
            "public.*" = {
              myapp = [ "EXECUTE" ];
              readonly = [ "EXECUTE" ];
            };
            "public.admin_function" = {
              admin = [ "EXECUTE" ];
            };
          };
        };

        # Default privileges (Phase 2)
        defaultPrivileges = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              owner = lib.mkOption {
                type = lib.types.str;
                description = "Role that creates the objects";
              };

              schema = lib.mkOption {
                type = lib.types.str;
                default = "public";
                description = "Schema where privileges apply";
              };

              tables = lib.mkOption {
                type = lib.types.attrsOf (lib.types.listOf (lib.types.enum [
                  "ALL" "SELECT" "INSERT" "UPDATE" "DELETE" "TRUNCATE" "REFERENCES" "TRIGGER"
                ]));
                default = {};
                description = "Default table privileges for each role";
              };

              sequences = lib.mkOption {
                type = lib.types.attrsOf (lib.types.listOf (lib.types.enum [
                  "ALL" "SELECT" "UPDATE" "USAGE"
                ]));
                default = {};
                description = "Default sequence privileges for each role";
              };

              functions = lib.mkOption {
                type = lib.types.attrsOf (lib.types.listOf (lib.types.enum [
                  "ALL" "EXECUTE"
                ]));
                default = {};
                description = "Default function privileges for each role";
              };
            };
          });
          default = {};
          description = ''
            Default privileges for future objects created by specific roles.
            This ensures permissions persist when tables/sequences are created/recreated.

            Structure: { policy_name = { owner = "...", schema = "...", tables/sequences/functions = {...}; }; }
          '';
          example = {
            app_defaults = {
              owner = "myapp";
              schema = "public";
              tables.readonly = [ "SELECT" ];
              sequences.readonly = [ "SELECT" "USAGE" ];
            };
          };
        };
      };
    });
    default = {};
    description = ''
      Declarative database provisioning configuration (Phase 1 + Phase 2).
      Each attribute defines a database to be created with the specified owner,
      extensions, and multi-level permissions (database, schema, table).

      The database name is derived from the attribute name.
      The owner role is created if it doesn't exist and granted ownership.

      SECURITY: Ensure ownerPasswordFile points to runtime secrets, never store paths.
      PERMISSIONS: Full PostgreSQL privilege hierarchy supported:
        - Database level: CONNECT, CREATE, TEMP
        - Schema level: USAGE, CREATE
        - Table level: SELECT, INSERT, UPDATE, DELETE, etc.
        - Default privileges: For future objects
    '';
  };
}
