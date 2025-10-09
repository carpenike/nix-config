{ lib, config, pkgs, ... }:

{
  config = {
    # Register ZFS replication notification templates if notification system is enabled
    modules.notifications.templates = lib.mkIf (config.modules.notifications.enable or false) {
      zfs-replication-failure = {
        enable = lib.mkDefault true;
        priority = lib.mkDefault "high";
        backend = lib.mkDefault "pushover";
        title = lib.mkDefault ''<b><font color="red">✗ ZFS Replication Failed</font></b>'';
        body = lib.mkDefault ''
          <b>Dataset:</b> <code>''${dataset}</code>
          <b>Target:</b> <code>nas-1.holthome.net</code>

          <b>Error:</b>
          <code>''${errorMessage}</code>

          <b>Actions:</b>
          1. Check Syncoid status:
             <code>systemctl status syncoid-''${dataset}</code>
          2. Test SSH connection:
             <code>ssh zfs-replication@nas-1 'zfs list'</code>
          3. Check recent snapshots:
             <code>zfs list -t snapshot | grep ''${dataset}</code>
        '';
      };

      zfs-snapshot-failure = {
        enable = lib.mkDefault true;
        priority = lib.mkDefault "high";
        backend = lib.mkDefault "pushover";
        title = lib.mkDefault ''<b><font color="red">✗ ZFS Snapshot Failed</font></b>'';
        body = lib.mkDefault ''
          <b>Dataset:</b> <code>''${dataset}</code>
          <b>Host:</b> ''${hostname}

          <b>Error:</b>
          <code>''${errorMessage}</code>

          <b>Actions:</b>
          1. Check Sanoid status:
             <code>systemctl status sanoid</code>
          2. Check ZFS pool health:
             <code>zpool status -v</code>
          3. Review Sanoid logs:
             <code>journalctl -u sanoid -n 50</code>
        '';
      };

      pool-degraded = {
        enable = lib.mkDefault true;
        priority = lib.mkDefault "emergency";
        backend = lib.mkDefault "pushover";
        title = lib.mkDefault ''<b><font color="red">🚨 URGENT: ZFS Pool Degraded</font></b>'';
        body = lib.mkDefault ''
          <b>Pool:</b> <code>''${pool}</code>
          <b>Host:</b> ''${hostname}
          <b>State:</b> <font color=\"red\">''${state}</font>

          <b>Pool Status:</b>
          <code>''${status}</code>

          <b>⚠️ IMMEDIATE ACTIONS REQUIRED:</b>
          1. Check pool status:
             <code>zpool status -v ''${pool}</code>
          2. Identify failed devices:
             <code>zpool list -v ''${pool}</code>
          3. Check system logs:
             <code>journalctl -u zfs-import.target -n 100</code>
          4. If device failed, replace and resilver:
             <code>zpool replace ''${pool} &lt;old_device&gt; &lt;new_device&gt;</code>

          ⚠️ Data redundancy is compromised. Do NOT ignore this alert.
        '';
      };
    };

    # Create static user for Sanoid (required for ZFS permissions)
    # By default, sanoid uses DynamicUser which creates an ephemeral user
    # We need a static user to grant ZFS permissions before the service starts
    users.users.sanoid = {
      isSystemUser = true;
      group = "sanoid";
      description = "Sanoid ZFS snapshot management user";
    };

    users.groups.sanoid = {};

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

    # Override sanoid service to use static user instead of DynamicUser
    # This allows us to grant ZFS permissions before the service starts
    systemd.services.sanoid.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "sanoid";
      Group = "sanoid";
    };

    # Wire Sanoid to notification system
    systemd.services.sanoid.unitConfig = {
      OnFailure = "notify@zfs-snapshot-failure:sanoid.service";
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

    # Override syncoid service sandboxing to allow SSH key access
    # With PrivateMounts=true, symlink resolution requires BOTH ends to be in BindReadOnlyPaths
    # ReadOnlyPaths alone doesn't work for symlinks across mount namespaces
    systemd.services.syncoid-rpool-safe-home.serviceConfig = {
      BindReadOnlyPaths = lib.mkForce [
        "/nix/store"
        "/etc"
        "/bin/sh"
        # Both symlink source and target must be explicitly bound for resolution
        "/var/lib/zfs-replication/.ssh"
        "/run/secrets/zfs-replication"
      ];
    };

    # Wire Syncoid services to notification system
    systemd.services.syncoid-rpool-safe-home.unitConfig = {
      OnFailure = "notify@zfs-replication-failure:rpool-safe-home.service";
    };

    systemd.services.syncoid-rpool-safe-persist.serviceConfig = {
      BindReadOnlyPaths = lib.mkForce [
        "/nix/store"
        "/etc"
        "/bin/sh"
        # Both symlink source and target must be explicitly bound for resolution
        "/var/lib/zfs-replication/.ssh"
        "/run/secrets/zfs-replication"
      ];
    };

    systemd.services.syncoid-rpool-safe-persist.unitConfig = {
      OnFailure = "notify@zfs-replication-failure:rpool-safe-persist.service";
    };    # Configure Syncoid for replication to nas-1
    services.syncoid = {
      enable = true;
      interval = "hourly";  # Run replication every hour

      # Run as zfs-replication user (matches SSH key ownership)
      user = "zfs-replication";
      group = "zfs-replication";

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

    # ZFS pool health monitoring
    systemd.services.zfs-health-check = {
      description = "Check ZFS pool health and notify on degraded state";

      serviceConfig = {
        Type = "oneshot";
        ExecStart = let
          checkScript = pkgs.writeShellScript "zfs-health-check" ''
            set -euo pipefail

            # Check each pool's health
            for pool in $(${pkgs.zfs}/bin/zpool list -H -o name); do
              state=$(${pkgs.zfs}/bin/zpool list -H -o health "$pool")

              # Trigger notification if pool is not ONLINE
              if [[ "$state" != "ONLINE" ]]; then
                # Get detailed status for notification body
                status=$(${pkgs.zfs}/bin/zpool status "$pool" 2>&1 || echo "Failed to get pool status")

                # Export variables for notification template
                export NOTIFY_POOL="$pool"
                export NOTIFY_HOSTNAME="${config.networking.hostName}"
                export NOTIFY_STATE="$state"
                export NOTIFY_STATUS="$status"

                # Trigger notification through dispatcher
                ${pkgs.systemd}/bin/systemctl start "notify@pool-degraded:$pool.service"

                echo "WARNING: Pool $pool is $state - notification sent"
              else
                echo "Pool $pool is ONLINE"
              fi
            done
          '';
        in "${checkScript}";
      };
    };

    # Run health check every 15 minutes
    systemd.timers.zfs-health-check = {
      description = "Periodic ZFS pool health check";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnBootSec = "5min";        # Check 5 minutes after boot
        OnUnitActiveSec = "15min"; # Then every 15 minutes
        Unit = "zfs-health-check.service";
      };
    };
  };
}
