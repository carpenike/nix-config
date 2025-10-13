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
        "zfs-replication/ssh-key" = {
          mode = "0600";
          owner = "zfs-replication";
          group = "zfs-replication";
          path = "/var/lib/zfs-replication/.ssh/id_ed25519";
        };

        # Pushover notification credentials
        "pushover/token" = {
          mode = "0400";
          owner = "root";
          group = "root";
        };
        "pushover/user-key" = {
          mode = "0400";
          owner = "root";
          group = "root";
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
      };
    };
  };
}
