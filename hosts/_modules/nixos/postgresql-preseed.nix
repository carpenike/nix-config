{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.postgresql.preSeed;
  pgCfg = config.services.postgresql;

  # Helper to determine if PGDATA is empty
  pgDataPath = pgCfg.dataDir;

  # Build the pgbackrest restore command
  restoreCommand = pkgs.writeShellScript "postgresql-preseed-restore" ''
    set -euo pipefail

    echo "=== PostgreSQL Pre-Seed Restore Starting ==="
    echo "Target: ${pgDataPath}"
    echo "Stanza: ${cfg.source.stanza}"
    echo "Backup Set: ${cfg.source.backupSet}"
    echo "Repository: ${toString cfg.source.repository}"

    # Safety check: Decide what to do if PGDATA is not empty
    if [ -d "${pgDataPath}" ] && [ "$(ls -A "${pgDataPath}" 2>/dev/null)" ]; then
      # If it looks like a healthy, initialized PGDATA, this is a no-op.
      # This handles enabling pre-seed on an existing server without errors.
      if [ -f "${pgDataPath}/postgresql.conf" ] && [ -f "${pgDataPath}/PG_VERSION" ]; then
        echo "PGDATA is already initialized. Skipping pre-seed restore."
        # Create the completion marker to ensure this check is skipped on future boots.
        touch "${pgDataPath}/.preseed-completed"
        echo "Completion marker created. Pre-seed service will be skipped in the future."
        exit 0
      else
        # If it's not empty but doesn't look initialized, it's a failed restore.
        echo "ERROR: PGDATA directory is not empty but appears incomplete."
        echo "This may indicate a previously failed restore."
        echo "To force a re-seed, stop postgresql, clear PGDATA, and reboot."
        exit 1
      fi
    fi

    # Create PGDATA directory if it doesn't exist
    mkdir -p "${pgDataPath}"
    chown postgres:postgres "${pgDataPath}"
    chmod 0700 "${pgDataPath}"    # Execute the restore
    echo "Running pgBackRest restore..."
    ${pkgs.pgbackrest}/bin/pgbackrest \
      --stanza=${cfg.source.stanza} \
      --repo=${toString cfg.source.repository} \
      ${optionalString (cfg.source.backupSet != "latest") "--set=${cfg.source.backupSet}"} \
      --type=immediate \
      --target-action=${cfg.targetAction} \
      --delta \
      --log-level-console=info \
      restore

    echo "=== pgBackRest restore completed successfully ==="

    # Run post-restore hook if configured
    ${optionalString (cfg.postRestoreScript != null) ''
      echo "=== Running post-restore sanitization script ==="
      ${cfg.postRestoreScript}
      echo "=== Post-restore sanitization completed ==="
    ''}

    # Create completion marker to prevent re-runs
    touch "${pgDataPath}/.preseed-completed"
    echo "=== Pre-Seed Restore Complete ==="
  '';

in {
  options.services.postgresql.preSeed = {
    enable = mkEnableOption "automatic restore of PostgreSQL from backup on empty PGDATA";

    environment = mkOption {
      type = types.nullOr (types.enum [ "production" "development" "staging" "test" ]);
      default = null;
      description = ''
        Environment type for multi-environment setups.

        For homelab/single-server setups: Leave as null (default).
        For production with staging: Set to prevent accidental production restores.

        When set to "production", the module will refuse to run (safety check).
        This is only useful if you have separate production AND staging configs.
      '';
    };

    source = {
      stanza = mkOption {
        type = types.str;
        example = "main";
        description = "pgBackRest stanza name to restore from";
      };

      repository = mkOption {
        type = types.int;
        default = 1;
        example = 2;
        description = ''
          pgBackRest repository number to restore from.

          repo1 (NFS) is RECOMMENDED for pre-seeding:
          - Faster restore (local network)
          - No egress costs
          - Has WAL files for more complete restore

          repo2 (R2) use cases:
          - Remote staging servers (not on NAS network)
          - Longer retention needs (30 days vs 7 days)
          - Testing offsite recovery procedures
        '';
      };

      backupSet = mkOption {
        type = types.str;
        default = "latest";
        example = "20231015-120000F";
        description = ''
          Backup set to restore. Use "latest" for most recent backup,
          or specify a backup label for consistent test environments.
        '';
      };
    };

    targetAction = mkOption {
      type = types.enum [ "promote" "shutdown" ];
      default = "promote";
      description = ''
        Action after restore completes. "promote" brings database online immediately,
        "shutdown" leaves it stopped for manual inspection (rarely needed).
      '';
    };

    postRestoreScript = mkOption {
      type = types.nullOr types.lines;
      default = null;
      example = literalExpression ''
        ''''
          echo "Sanitizing PII..."
          ''${pkgs.postgresql}/bin/psql -d myapp -U postgres <<SQL
            UPDATE users SET email = 'user-' || id || '@example.com';
            UPDATE customers SET phone = '555-0000';
          SQL
        ''''
      '';
      description = ''
        Script to run after restore but before PostgreSQL starts.
        Critical for data sanitization, PII removal, and test data generation.
        Runs as the postgres user with PGDATA available but PostgreSQL not yet running.
      '';
    };
  };

  config = mkIf cfg.enable {
    # SAFETY CHECK: Prevent accidental auto-restore in multi-environment setups
    # For homelab: This check is effectively disabled (environment = null)
    # For prod+staging: Set environment = "production" to block auto-restore
    assertions = [
      {
        assertion = cfg.environment != "production";
        message = ''
          ERROR: PostgreSQL automatic restore is DISABLED when environment = "production".

          This safety check prevents auto-restore on production servers in multi-environment setups.

          For homelab disaster recovery: Set environment = null (or omit it entirely)
          For staging/dev environments: Set environment = "staging" or "test"

          If you need to restore production, either:
          1. Temporarily set environment = null to allow auto-restore
          2. Use manual restore: pgbackrest --stanza=main --repo=1 restore
        '';
      }
      {
        assertion = pgCfg.enable;
        message = "PostgreSQL must be enabled to use pre-seed restore";
      }
      {
        assertion = cfg.source.stanza != "";
        message = "pgBackRest stanza name must be specified for pre-seed restore";
      }
    ];

    # Create the systemd service for pre-seeding
    systemd.services.postgresql-preseed = {
      description = "PostgreSQL Pre-Seed Restore (New Server Provisioning)";
      wantedBy = [ "multi-user.target" ];
      before = [ "postgresql.service" ];
      after = [ "network-online.target" "systemd-tmpfiles-setup.service" "mnt-nas\\x2dpostgresql.mount" ];
      wants = [ "network-online.target" "mnt-nas\\x2dpostgresql.mount" ];
      requires = [ "systemd-tmpfiles-setup.service" "mnt-nas\\x2dpostgresql.mount" ];

      # Only run if PGDATA doesn't contain the completion marker
      unitConfig = {
        ConditionPathExists = "!${pgDataPath}/.preseed-completed";
      };

      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        ExecStart = "${restoreCommand}";

        # Security hardening - relaxed for NFS mount access
        PrivateTmp = true;
        NoNewPrivileges = true;
        # CRITICAL: Cannot use ProtectSystem=strict with NFS automounts
        # Status 226 (NAMESPACE) indicates namespace isolation blocking network filesystem access
        # NFS mounts require full filesystem namespace access
        ProtectSystem = "full";  # Changed from "strict" to allow NFS mount access
        ProtectHome = true;
        ReadWritePaths = [
          pgDataPath                      # PostgreSQL data directory
          "/var/lib/pgbackrest"           # pgBackRest working directory and spool
          "/var/log/pgbackrest"           # pgBackRest log directory
          "/mnt/nas-postgresql"           # NFS backup repository (repo1) - corrected from nas-backup
        ];

        # Timeout: Restores can take a while for large databases
        TimeoutStartSec = "2h";

        # Don't restart on failure - manual intervention needed
        Restart = "no";
      };
    };

    # Ensure PostgreSQL service waits for pre-seed if needed
    systemd.services.postgresql = {
      after = [ "postgresql-preseed.service" ];
      wants = [ "postgresql-preseed.service" ];
    };

    # Add helpful environment indicator
    environment.etc."postgresql-preseed-info".text = ''
      PostgreSQL Pre-Seed Configuration
      ==================================
      Environment: ${if cfg.environment != null then cfg.environment else "homelab (unspecified)"}
      Stanza: ${cfg.source.stanza}
      Repository: repo${toString cfg.source.repository}
      Backup Set: ${cfg.source.backupSet}

      This database will be automatically seeded from backup on first boot
      if PGDATA is empty. Subsequent boots will skip the restore.

      To force a re-seed:
      1. Stop PostgreSQL: systemctl stop postgresql
      2. Remove PGDATA: rm -rf ${pgDataPath}/*
      3. Remove completion marker: rm -f ${pgDataPath}/.preseed-completed
      4. Start PostgreSQL: systemctl start postgresql

      WARNING: This will destroy all local data!
    '';
  };
}
