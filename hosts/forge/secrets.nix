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
        # Restic backup password
        "restic/password" = {
          mode = "0400";
          owner = "restic-backup";
          group = "restic-backup";
        };

        # ZFS replication SSH key
        "zfs-replication/ssh-key" = {
          mode = "0600";
          owner = "zfs-replication";
          group = "zfs-replication";
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
      };
    };
  };
}
