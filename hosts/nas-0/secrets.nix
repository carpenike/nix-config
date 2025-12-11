# hosts/nas-0/secrets.nix
#
# SOPS secrets configuration for nas-0
#
# Required secrets:
# - zfs-replication/ssh-key: SSH private key for syncoid to nas-1

{ ... }:

{
  sops = {
    defaultSopsFile = ./secrets.sops.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      # ZFS replication SSH key for sending to nas-1
      "zfs-replication/ssh-key" = {
        owner = "zfs-replication";
        group = "zfs-replication";
        mode = "0600";
        path = "/var/lib/zfs-replication/.ssh/id_ed25519";
      };

      # Restic password for B2 offsite backup (optional - for system config backup)
      # "restic/nas-0-password" = {
      #   owner = "restic-backup";
      #   group = "restic-backup";
      #   mode = "0400";
      # };
    };
  };

  # Ensure .ssh directory exists for zfs-replication user
  systemd.tmpfiles.rules = [
    "d /var/lib/zfs-replication/.ssh 0700 zfs-replication zfs-replication -"
  ];
}
