{
  pkgs,
  ...
}:
{
  config = {
    environment.systemPackages = [
      pkgs.sops
      pkgs.age
    ];

    sops = {
      defaultSopsFile = ./secrets.sops.yaml;
      age.sshKeyPaths = [
        "/etc/ssh/ssh_host_ed25519_key"
      ];
      secrets = {
        # Restic backup password (used for local NFS and R2 encryption)
        "restic/password" = {
          mode = "0400";
          owner = "restic-backup";
          group = "restic-backup";
        };

        # Cloudflare R2 API credentials for offsite backups
        # Bucket: nix-homelab-prod-servers (forge, luna, nas-1)
        # Contains: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (R2 is S3-compatible)
        # Security: Scoped token with access ONLY to production-servers bucket
        # Used by: restic-backup service AND pgBackRest (postgres user needs read access)
        "restic/r2-prod-env" = {
          mode = "0440";
          owner = "restic-backup";
          group = "restic-backup";
        };

        # ZFS replication SSH key
        # Ephemeral secret (preferred): do not set a persistent path so sops-nix
        # writes the decrypted key under /run/secrets and we reference it via
        # config.sops.secrets."zfs-replication/ssh-key".path
        "zfs-replication/ssh-key" = {
          mode = "0600";
          owner = "zfs-replication";
          group = "zfs-replication";
        };

        # Pushover notification credentials (for Alertmanager)
        # Alertmanager needs to read these files
        "pushover/token" = {
          mode = "0440";
          owner = "root";
          group = "alertmanager";
        };
        "pushover/user-key" = {
          mode = "0440";
          owner = "root";
          group = "alertmanager";
        };

        # Healthchecks.io webhook URL for dead man's switch
        "monitoring/healthchecks-url" = {
          mode = "0440";
          owner = "root";
          group = "alertmanager";
        };

        # PostgreSQL database passwords
        # Group-readable so postgresql-provision-databases.service (runs as postgres user)
        # can hash the file for change detection. PostgreSQL server reads via pg_read_file()
        # which has superuser privileges and doesn't need filesystem permissions.
        "postgresql/dispatcharr_password" = {
          mode = "0440";  # owner+group read
          owner = "root";
          group = "postgres";
        };

        # Cloudflare API token for Caddy DNS-01 ACME challenges
        # Reusing the same token structure as Luna for consistency
        "networking/cloudflare/ddns/apiToken" = {
          mode = "0400";
          owner = "caddy";
          group = "caddy";
        };

        # Loki Basic Auth password hash for Caddy reverse proxy (environment variable)
        "services/caddy/environment/loki-admin-bcrypt" = {
          mode = "0400";
          owner = "caddy";
          group = "caddy";
        };

        # Loki Basic Auth password hash for Caddy reverse proxy (file-based)
        "caddy/loki-admin-bcrypt" = {
          mode = "0400";
          owner = "caddy";
          group = "caddy";
        };

        # Grafana admin password
        "grafana/admin-password" = {
          mode = "0400";
          owner = "grafana";
          group = "grafana";
        };

        # Grafana OIDC client secret (must match Authelia)
        "grafana/oidc_client_secret" = {
          mode = "0400";
          owner = "grafana";
          group = "grafana";
        };

        # Authelia secrets
        "authelia/jwt_secret" = {
          mode = "0400";
          owner = "authelia-main";
          group = "authelia-main";
        };

        "authelia/session_secret" = {
          mode = "0400";
          owner = "authelia-main";
          group = "authelia-main";
        };

        "authelia/storage_encryption_key" = {
          mode = "0400";
          owner = "authelia-main";
          group = "authelia-main";
        };

        "authelia/oidc/hmac_secret" = {
          mode = "0400";
          owner = "authelia-main";
          group = "authelia-main";
        };

        "authelia/oidc/issuer_private_key" = {
          mode = "0400";
          owner = "authelia-main";
          group = "authelia-main";
        };

        "authelia/oidc/grafana_client_secret" = {
          mode = "0400";
          owner = "authelia-main";
          group = "authelia-main";
        };

        "authelia/smtp_password" = {
          mode = "0400";
          owner = "authelia-main";
          group = "authelia-main";
        };

        "authelia/users.yaml" = {
          path = "/var/lib/authelia-main/users.yaml";
          mode = "0400";
          owner = "authelia-main";
          group = "authelia-main";
        };
      };
    };
  };
}
