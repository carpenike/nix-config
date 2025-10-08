{ pkgs, ... }:

{
  config = {
    # Create dedicated user for ZFS replication
    users.users.zfs-replication = {
      isSystemUser = true;
      group = "zfs-replication";
      home = "/var/lib/zfs-replication";
      createHome = true;
      shell = pkgs.nologin;
      description = "ZFS replication service user";
    };

    users.groups.zfs-replication = {};

    # Manage SSH private key via SOPS
    sops.secrets."zfs-replication/ssh-key" = {
      owner = "zfs-replication";
      group = "zfs-replication";
      mode = "0600";
      path = "/var/lib/zfs-replication/.ssh/id_ed25519";
    };

    # Create .ssh directory with proper permissions
    systemd.tmpfiles.rules = [
      "d /var/lib/zfs-replication/.ssh 0700 zfs-replication zfs-replication -"
    ];

    # Grant ZFS permissions for sending snapshots
    # Note: These need to be run manually after first boot:
    # sudo zfs allow zfs-replication send,snapshot,hold rpool
    # sudo zfs allow zfs-replication send,snapshot,hold tank

    # Future: systemd service for automated replication will go here
  };
}
