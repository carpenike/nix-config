{ lib, pkgs, config, ... }:
# PostgreSQL Module - Simplified Single-Instance Design
#
# This module defines options and generates PostgreSQL service configuration.
# Integration with storage/backup is handled by respective integration modules.
#
# Architecture: Single PostgreSQL instance with multiple databases
# - Options defined as a single submodule (not attrsOf)
# - Service generation included in this file (no separate implementation.nix)
# - Storage/backup integration remains in separate modules
{
  options.modules.services.postgresql = lib.mkOption {
    type = lib.types.submodule {
      options = {
      enable = lib.mkEnableOption "PostgreSQL service";

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

      # Computed paths (read-only, derived from version)
      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/postgresql/${config.modules.services.postgresql.version}";
        readOnly = true;
        description = "PostgreSQL data directory";
      };

      walArchiveDir = lib.mkOption {
        type = lib.types.str;
        default = "${config.modules.services.postgresql.dataDir}-wal-archive";
        readOnly = true;
        description = "PostgreSQL WAL archive directory";
      };

      # Database declarations
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
    };
    default = {};
    description = "PostgreSQL service with PITR support";
  };

  config =
    let
      cfg = config.modules.services.postgresql;
      pgPackage = if cfg.enable then pkgs.${"postgresql_${lib.replaceStrings ["."] [""] cfg.version}"} else null;
    in
    lib.mkMerge [
    # PostgreSQL service implementation
    (lib.mkIf cfg.enable {
      # Operational safety warnings
      warnings =
        (lib.optional (!(cfg.backup.walArchive.enable or false)
                    && !(cfg.backup.baseBackup.enable or false)
                    && !(cfg.extraSettings.archive_mode or false == "on"))
          "modules.services.postgresql: Both WAL archiving and base backups are disabled, and no custom archive_mode is configured - no PITR capability")
        ++ (lib.optional (cfg.databases == {})
          "modules.services.postgresql: No databases configured - PostgreSQL is enabled but no databases will be provisioned");
      # Enable the base PostgreSQL service
      services.postgresql = {
        enable = true;
        package = pgPackage;
        dataDir = cfg.dataDir;

        # Basic configuration
        settings = lib.mkMerge [
          {
            port = cfg.port;
            listen_addresses = lib.mkDefault cfg.listenAddresses;
            max_connections = lib.mkDefault cfg.maxConnections;

            # Memory settings
            shared_buffers = lib.mkDefault cfg.sharedBuffers;
            effective_cache_size = lib.mkDefault cfg.effectiveCacheSize;
            work_mem = lib.mkDefault cfg.workMem;
            maintenance_work_mem = lib.mkDefault cfg.maintenanceWorkMem;

            # Logging
            log_destination = lib.mkDefault "stderr";
            logging_collector = lib.mkDefault true;
            log_directory = lib.mkDefault "log";
            log_filename = lib.mkDefault "postgresql-%Y-%m-%d_%H%M%S.log";
            log_rotation_age = lib.mkDefault "1d";
            log_rotation_size = lib.mkDefault "100MB";
            log_line_prefix = lib.mkDefault "%m [%p] %u@%d ";
            log_timezone = lib.mkDefault "UTC";
          }

          # WAL archiving for Point-in-Time Recovery (PITR)
          (lib.mkIf (cfg.backup.walArchive.enable or false) {
            # Enable WAL archiving
            archive_mode = "on";

            # Compress WAL files to reduce storage and I/O overhead
            wal_compression = "on";

            # Archive command uses atomic write pattern (cp to temp, then mv)
            archive_command = "test ! -f ${cfg.walArchiveDir}/%f && cp %p ${cfg.walArchiveDir}/.tmp.%f && mv ${cfg.walArchiveDir}/.tmp.%f ${cfg.walArchiveDir}/%f";

            # Archive timeout - force WAL segment switch after this interval
            archive_timeout = toString cfg.backup.walArchive.archiveTimeout;
          })

          # Merge in user's extra settings (can override defaults)
          cfg.extraSettings
        ];

        # Enable authentication
        authentication = lib.mkDefault ''
          local all postgres peer
          local all all peer
          host all all 127.0.0.1/32 scram-sha-256
          host all all ::1/128 scram-sha-256
        '';
      };

      # Ensure WAL archive directory exists with correct permissions
      systemd.tmpfiles.rules = lib.optionals (cfg.backup.walArchive.enable or false) [
        "d ${cfg.walArchiveDir} 0750 postgres postgres -"
      ];

      # Extend systemd service configuration
      systemd.services.postgresql = {
        # Ensure PostgreSQL doesn't start until required directories are mounted
        unitConfig = {
          RequiresMountsFor = [ cfg.dataDir ] ++ lib.optional (cfg.backup.walArchive.enable or false) cfg.walArchiveDir;
        };

        # Ensure ZFS mounts are complete before starting
        after = [ "zfs-mount.service" ];

        # Runtime checks for WAL archive directory
        serviceConfig = {
          ExecStartPre = lib.optionals (cfg.backup.walArchive.enable or false) [
            "${pkgs.coreutils}/bin/test -d '${cfg.walArchiveDir}'"
            "${pkgs.coreutils}/bin/test -w '${cfg.walArchiveDir}'"
          ];
          # Allow write access to WAL archive directory when PITR is enabled
          ReadWritePaths = lib.optionals (cfg.backup.walArchive.enable or false) [ cfg.walArchiveDir ];
        };
      };
    })

    # Notification templates
    (lib.mkIf (config.modules.notifications.enable or false) {
      modules.notifications.templates = {
        postgresql-backup-success = {
          enable = true;
          priority = "normal";
          title = "✅ PostgreSQL Backup Complete";
          body = ''
            <b>Backup Path:</b> ''${backuppath}
            <b>Status:</b> Success
          '';
        };

        postgresql-backup-failure = {
          enable = true;
          priority = "high";
          title = "✗ PostgreSQL Backup Failed";
          body = ''
            <b>Error:</b> ''${errormessage}
            <b>Action Required:</b> Check backup logs
          '';
        };

        postgresql-health-failure = {
          enable = true;
          priority = "high";
          title = "⚠ PostgreSQL Health Check Failed";
          body = ''
            <b>Error:</b> ''${errormessage}
            <b>Action Required:</b> Check PostgreSQL service status
          '';
        };

        postgresql-replication-lag = {
          enable = true;
          priority = "normal";
          title = "⚠ PostgreSQL Replication Lag";
          body = ''
            <b>Lag:</b> ''${lag} seconds
            <b>Status:</b> Replication is falling behind
          '';
        };
      };
    })
  ];
}
