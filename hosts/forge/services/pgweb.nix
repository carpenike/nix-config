# pgweb - PostgreSQL Web Interface
#
# Auxiliary database admin tool for PostgreSQL. Connects to PostgreSQL
# instance managed by postgresql.nix.
#
# Infrastructure Contributions:
#   - Backup: Not applicable (stateless - all data lives in PostgreSQL)
#   - Sanoid: Not applicable (no ZFS dataset)
#   - Monitoring: None (auxiliary tool, not critical infrastructure)
#                 PostgreSQL itself has comprehensive monitoring.
{ config, lib, ... }:

let
  serviceEnabled = config.modules.services.pgweb.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.pgweb = {
        enable = true;
        port = 8081;
        listenAddress = "127.0.0.1";

        database = {
          host = "localhost";
          port = 5432;
          user = "pgweb";
          database = "postgres";
          passwordFile = config.sops.secrets."postgresql/pgweb_password".path;
        };

        reverseProxy = {
          enable = true;
          hostName = "pgweb.${config.networking.domain}";
          # Protect via Pocket ID + caddy-security; restrict access to admins only.
          caddySecurity = {
            enable = true;
            portal = "pocketid";
            policy = "admins";
            claimRoles = [
              {
                claim = "groups";
                value = "admins";
                role = "admins";
              }
            ];
          };

          backend = {
            scheme = "http";
            host = "127.0.0.1";
            port = 8081;
          };
          security = {
            hsts.enable = true;
          };
        };

        metrics = {
          enable = true;
        };
      };

      sops.secrets."postgresql/pgweb_password" = {
        mode = "0440";
        owner = "root";
        # Provisioning runs as the postgres user and needs to read the file
        group = "postgres";
      };

      # Pgweb admin password hash is loaded via sops.templates."caddy-env" in default.nix
      sops.secrets."services/caddy/environment/pgweb-admin-bcrypt" = {
        mode = "0400";
        owner = "caddy";
        group = "caddy";
      };
    }

    (lib.mkIf serviceEnabled {
      # Create a pgweb login user and grant it readonly role membership
      # This gives pgweb SELECT access to all databases via the readonly role
      modules.services.postgresql.databases._pgweb_user = {
        owner = "pgweb";
        ownerPasswordFile = config.sops.secrets."postgresql/pgweb_password".path;
        # Use custom permissions to grant readonly role membership
        permissionsPolicy = "custom";
        databasePermissions.readonly = [ "CONNECT" ]; # Inherit from readonly role
      };

      # Configure readonly role permissions using PostgreSQL-native template1 pattern
      # This ensures all future databases automatically inherit readonly access
      systemd.services.postgresql-setup-readonly-role = {
        description = "Configure readonly role permissions via template1";
        after = [ "postgresql.service" "postgresql-provision-databases.service" ];
        wants = [ "postgresql.service" "postgresql-provision-databases.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          RemainAfterExit = true;
        };

        script = ''
          set -euo pipefail

          # Grant readonly role to pgweb user
          ${config.services.postgresql.package}/bin/psql -d postgres -c "GRANT readonly TO pgweb;"

          # Configure template1 for all future databases
          echo "Configuring template1 database for readonly access..."
          ${config.services.postgresql.package}/bin/psql -d template1 <<'SQL'
            -- Grant usage on public schema
            GRANT USAGE ON SCHEMA public TO readonly;

            -- Grant SELECT ON existing tables in template1
            GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;

            -- Set default privileges for future tables created by any user
            ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly;

            -- Grant CONNECT on template1 (will be inherited by new databases)
            GRANT CONNECT ON DATABASE template1 TO readonly;
          SQL

          # Backfill permissions for existing databases
          echo "Backfilling permissions for existing databases..."
          for db in $(${config.services.postgresql.package}/bin/psql -t -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1') AND NOT datistemplate;"); do
            db=$(echo "$db" | xargs) # Trim whitespace
            echo "  Updating database: $db"

            # Grant CONNECT on the database
            ${config.services.postgresql.package}/bin/psql -d postgres -c "GRANT CONNECT ON DATABASE \"$db\" TO readonly;"

            # Grant schema and table access inside the database
            ${config.services.postgresql.package}/bin/psql -d "$db" <<SQL
              GRANT USAGE ON SCHEMA public TO readonly;
              GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;
              ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly;
          SQL
          done

          echo "Readonly role configuration complete."
        '';
      };
    })
  ];
}
