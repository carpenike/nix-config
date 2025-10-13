{ lib, config, ... }:
# PostgreSQL Module - Options Only
#
# This module ONLY defines options for PostgreSQL instances.
# Service generation is handled by implementation.nix.
# Integration with storage/backup is handled by respective integration modules.
{
  options.modules.services.postgresql = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
      options = {
        enable = lib.mkEnableOption "PostgreSQL instance";

        version = lib.mkOption {
          type = lib.types.enum [ "14" "15" "16" ];
          default = "16";
          description = "PostgreSQL major version";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 5432;
          description = "PostgreSQL port";
        };

        listenAddresses = lib.mkOption {
          type = lib.types.str;
          default = "localhost";
          description = "Addresses to listen on (comma-separated)";
        };

        maxConnections = lib.mkOption {
          type = lib.types.int;
          default = 100;
          description = "Maximum number of concurrent connections";
        };

        # Memory tuning
        sharedBuffers = lib.mkOption {
          type = lib.types.str;
          default = "256MB";
          description = "Amount of memory for shared buffers";
        };

        effectiveCacheSize = lib.mkOption {
          type = lib.types.str;
          default = "1GB";
          description = "Planner's assumption of effective cache size";
        };

        workMem = lib.mkOption {
          type = lib.types.str;
          default = "4MB";
          description = "Memory for internal sort operations and hash tables";
        };

        maintenanceWorkMem = lib.mkOption {
          type = lib.types.str;
          default = "64MB";
          description = "Memory for maintenance operations";
        };

        # Database declarations (nested approach - replaces simple list and global databases option)
        databases = lib.mkOption {
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

              # Database-level permissions
              databasePermissions = lib.mkOption {
                type = lib.types.attrsOf (lib.types.listOf (lib.types.enum [
                  "ALL" "CONNECT" "CREATE" "TEMP" "TEMPORARY"
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

              # Schema-level permissions
              schemaPermissions = lib.mkOption {
                type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf (lib.types.enum [
                  "ALL" "USAGE" "CREATE"
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
                };
              };

              # Table-level permissions
              tablePermissions = lib.mkOption {
                type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf (lib.types.enum [
                  "ALL" "SELECT" "INSERT" "UPDATE" "DELETE" "TRUNCATE" "REFERENCES" "TRIGGER" "EXECUTE"
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
                  - EXECUTE: Execute functions/procedures (only valid with wildcard patterns)
                '';
                example = {
                  "public.*" = {
                    readonly = [ "SELECT" ];
                    myapp = [ "ALL" ];
                  };
                };
              };

              # Function-level permissions
              functionPermissions = lib.mkOption {
                type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf (lib.types.enum [
                  "ALL" "EXECUTE"
                ])));
                default = {};
                description = ''
                  Function-level permissions to grant to roles.
                  Structure: { schema_name.function_pattern = { role_name = [ privileges ]; }; }

                  Use "*" as function_pattern to match all functions in a schema.

                  Valid PostgreSQL function privileges:
                  - ALL: All function privileges (just EXECUTE currently)
                  - EXECUTE: Execute functions and procedures
                '';
                example = {
                  "public.*" = {
                    myapp = [ "EXECUTE" ];
                  };
                };
              };

              # Default privileges
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
            Databases to provision for this PostgreSQL instance.
            Each database is declaratively configured with owner, extensions, and permissions.

            Example:
              modules.services.postgresql.main.databases.myapp = {
                owner = "myapp";
                ownerPasswordFile = "/run/secrets/myapp-db-password";
                extensions = [ "pg_trgm" "btree_gin" ];
                permissionsPolicy = "owner-readwrite+readonly-select";
              };
          '';
        };

        # WAL archiving configuration
        backup.walArchive = {
          enable = lib.mkEnableOption "WAL archiving" // { default = true; };

          archiveTimeout = lib.mkOption {
            type = lib.types.int;
            default = 300;
            description = "Force WAL switch after this many seconds (bounds RPO)";
          };

          syncInterval = lib.mkOption {
            type = lib.types.str;
            default = "*/5";
            description = "How often to sync WAL archive to off-site storage (systemd OnCalendar format, e.g., '*/5' for every 5 minutes)";
          };

          retentionDays = lib.mkOption {
            type = lib.types.int;
            default = 30;
            description = "How long to retain WAL archives (days)";
          };
        };

        # Base backup configuration
        backup.baseBackup = {
          enable = lib.mkEnableOption "base backups" // { default = true; };

          schedule = lib.mkOption {
            type = lib.types.str;
            default = "daily";
            description = "Backup schedule (systemd timer format)";
          };

          retention = lib.mkOption {
            type = lib.types.submodule {
              options = {
                daily = lib.mkOption { type = lib.types.int; default = 7; };
                weekly = lib.mkOption { type = lib.types.int; default = 4; };
                monthly = lib.mkOption { type = lib.types.int; default = 3; };
              };
            };
            default = {};
            description = "Backup retention policy";
          };
        };

        # Restic integration
        backup.restic = {
          enable = lib.mkEnableOption "Restic backups" // { default = true; };

          repositoryName = lib.mkOption {
            type = lib.types.str;
            description = "Name of a configured Restic repository (e.g., 'nas-primary')";
          };

          repositoryUrl = lib.mkOption {
            type = lib.types.str;
            description = "Restic repository URL (for preseed restore_command)";
          };

          passwordFile = lib.mkOption {
            type = lib.types.path;
            description = "Path to Restic password file";
          };

          environmentFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to environment file for Restic (S3 credentials, etc.)";
          };
        };

        # Preseed configuration (automatic first-boot restoration)
        preseed = {
          enable = lib.mkEnableOption "preseed (automatic first-boot restoration)" // { default = false; };

          restoreMethods = lib.mkOption {
            type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
            default = [ "syncoid" "local" "restic" ];
            description = ''
              Ordered list of restore methods to try on first boot.
              - syncoid: Fast full data directory restore from remote ZFS snapshot via syncoid
              - local: Restore from local ZFS snapshot (if available)
              - restic: PITR bootstrap from Restic (restore base backup + replay WAL)
            '';
          };

          asStandby = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Keep standby.signal after restore to start as a standby server.
              If false (default), recovery.signal and standby.signal are removed after restore.
            '';
          };

          clearReplicationSlots = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Clear replication slots after restore to avoid WAL pinning on newly promoted primaries.
              Disable only if explicitly restoring as a standby with existing slots.
            '';
          };

          pitr = {
            target = lib.mkOption {
              type = lib.types.enum [ "latest" "time" "xid" "name" ];
              default = "latest";
              description = "PITR target type for pitr-restic restore method";
            };

            targetValue = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "PITR target value (timestamp for 'time', xid for 'xid', name for 'name')";
              example = "2025-10-10 12:00:00";
            };
          };

          repositoryUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Restic repository URL (defaults to backup.restic.repositoryUrl)";
          };

          passwordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Restic password file (defaults to backup.restic.passwordFile)";
          };

          environmentFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Restic environment file (defaults to backup.restic.environmentFile)";
          };
        };

        # Recovery configuration (PITR)
        recovery = {
          enable = lib.mkEnableOption "recovery mode (PITR)";

          target = lib.mkOption {
            type = lib.types.enum [ "immediate" "time" "xid" "name" ];
            default = "immediate";
            description = "Recovery target type";
          };

          targetTime = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Recovery target timestamp (ISO 8601 format)";
            example = "2025-10-10 12:00:00";
          };

          targetXid = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Recovery target transaction ID";
          };

          targetName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Recovery target restore point name";
          };
        };

        # Health checks
        healthCheck = {
          enable = lib.mkEnableOption "health checks" // { default = true; };

          interval = lib.mkOption {
            type = lib.types.str;
            default = "1min";
            description = "Health check interval";
          };

          checkReplicationLag = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Check replication lag (for standby servers)";
          };

          maxReplicationLagSeconds = lib.mkOption {
            type = lib.types.int;
            default = 300;
            description = "Maximum acceptable replication lag in seconds";
          };
        };

        # Extra PostgreSQL settings
        extraSettings = lib.mkOption {
          type = lib.types.attrs;
          default = {};
          description = "Additional PostgreSQL configuration settings";
        };

        # Integration toggles (hybrid approach: auto-wire by default, opt-out for explicit orchestration)
        integration = {
          storage = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Automatically create ZFS datasets for this PostgreSQL instance.
                Set to false to manually configure storage in host config.
              '';
            };
          };

          backup = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Automatically create Restic backup jobs for this PostgreSQL instance.
                Set to false to manually configure backups in host config.
              '';
            };
          };
        };
      };

      # NOTE: Submodule config can't set top-level options like services.postgresql
      # Configuration is generated at parent module level instead
    }));
    default = {};
    description = "PostgreSQL instances with PITR support";
  };

  config = lib.mkMerge [
    # Assertions
    {
      # NOTE: Single-instance limitation documented in module description
      # User should only enable one instance due to NixOS services.postgresql constraints
    }

    # NOTE: Config generation must be in a separate module (implementation.nix) to avoid circular dependency
    # Keeping the config generation here causes infinite recursion because we'd be reading
    # config.modules.services.postgresql while also defining it
    {}

    # Notification templates
    (lib.mkIf (config.modules.notifications.enable or false) {
      modules.notifications.templates = {
        postgresql-backup-success = {
          enable = true;
          priority = "normal";
          title = "✅ PostgreSQL Backup Complete";
          body = ''
            <b>Instance:</b> ''${instance}
            <b>Backup Path:</b> ''${backuppath}
            <b>Status:</b> Success
          '';
        };

        postgresql-backup-failure = {
          enable = true;
          priority = "high";
          title = "✗ PostgreSQL Backup Failed";
          body = ''
            <b>Instance:</b> ''${instance}
            <b>Error:</b> ''${errormessage}
            <b>Action Required:</b> Check backup logs
          '';
        };

        postgresql-health-failure = {
          enable = true;
          priority = "high";
          title = "⚠ PostgreSQL Health Check Failed";
          body = ''
            <b>Instance:</b> ''${instance}
            <b>Error:</b> ''${errormessage}
            <b>Action Required:</b> Check PostgreSQL service status
          '';
        };

        postgresql-replication-lag = {
          enable = true;
          priority = "normal";  # Changed from "medium" (not a valid priority)
          title = "⚠ PostgreSQL Replication Lag";
          body = ''
            <b>Instance:</b> ''${instance}
            <b>Lag:</b> ''${lag} seconds
            <b>Status:</b> Replication is falling behind
          '';
        };
      };
    })
  ];

  # FIXME: Database provisioning module creates circular dependency
  # databases.nix tries to read config.modules.services.postgresql.databases
  # which is part of the same config tree this module defines
  # Need to restructure database provisioning to avoid this circular reference
  # imports = [ ./databases.nix ];
}
