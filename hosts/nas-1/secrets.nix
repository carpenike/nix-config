# hosts/nas-1/secrets.nix
#
# SOPS secrets configuration for nas-1
#
# nas-1 is primarily a replication RECEIVER, so it has minimal secrets.
# The zfs-replication user authenticates via SSH public key (in users.nix).

{ ... }:

{
  sops = {
    defaultSopsFile = ./secrets.sops.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      # Restic password for B2 offsite backup (optional - for system config backup)
      # "restic/nas-1-password" = {
      #   owner = "restic-backup";
      #   group = "restic-backup";
      #   mode = "0400";
      # };
    };
  };
}
