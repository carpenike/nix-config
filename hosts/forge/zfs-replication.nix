{ ... }:

{
  config = {
    # Create dedicated user for ZFS replication
    users.users.zfs-replication = {
      isSystemUser = true;
      group = "zfs-replication";
      home = "/var/lib/zfs-replication";
      createHome = true;
      shell = "/run/current-system/sw/bin/nologin";
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

    # Automatically grant ZFS permissions at boot
    # This makes the system fully declarative and reproducible
    systemd.services.zfs-delegate-permissions = {
      description = "Delegate ZFS permissions for Sanoid and Syncoid";
      wantedBy = [ "multi-user.target" ];
      after = [ "zfs-import.target" "systemd-sysusers.service" ];
      before = [ "sanoid.service" "syncoid.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Grant permissions for Sanoid to manage snapshots
        /run/current-system/sw/bin/zfs allow sanoid send,snapshot,hold,destroy rpool/safe/home
        /run/current-system/sw/bin/zfs allow sanoid send,snapshot,hold,destroy rpool/safe/persist

        # Grant permissions for Syncoid to send snapshots for replication
        /run/current-system/sw/bin/zfs allow zfs-replication send,snapshot,hold rpool/safe/home
        /run/current-system/sw/bin/zfs allow zfs-replication send,snapshot,hold rpool/safe/persist

        echo "ZFS delegated permissions applied successfully"
      '';
    };

    # Configure Sanoid for snapshot management
    services.sanoid = {
      enable = true;

      # Template for common snapshot settings
      templates = {
        production = {
          hourly = 24;      # Keep 24 hourly snapshots
          daily = 7;        # Keep 7 daily snapshots
          weekly = 4;       # Keep 4 weekly snapshots
          monthly = 3;      # Keep 3 monthly snapshots
          yearly = 0;       # Don't keep yearly snapshots
          autosnap = true;  # Automatically create snapshots
          autoprune = true; # Automatically prune old snapshots
        };
      };

      # Dataset configurations
      datasets = {
        "rpool/safe/home" = {
          useTemplate = [ "production" ];
          recursive = false;  # Don't snapshot child datasets
        };

        "rpool/safe/persist" = {
          useTemplate = [ "production" ];
          recursive = false;
        };
      };
    };

    # Configure Syncoid for replication to nas-1
    services.syncoid = {
      enable = true;
      interval = "hourly";  # Run replication every hour

      # Use the zfs-replication user's SSH key
      sshKey = "/var/lib/zfs-replication/.ssh/id_ed25519";

      commands = {
        # Replicate home dataset
        "rpool/safe/home" = {
          target = "zfs-replication@nas-1.holthome.net:backup/forge/zfs-recv/home";
          recursive = false;
          sendOptions = "w";  # Send raw encrypted datasets
          recvOptions = "u";  # Receive without mounting
        };

        # Replicate persist dataset
        "rpool/safe/persist" = {
          target = "zfs-replication@nas-1.holthome.net:backup/forge/zfs-recv/persist";
          recursive = false;
          sendOptions = "w";
          recvOptions = "u";
        };
      };
    };
  };
}
