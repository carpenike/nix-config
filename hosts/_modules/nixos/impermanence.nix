{ lib
, config
, ...
}:
let
  cfg = config.modules.system.impermanence;
in
with lib;
{
  options.modules.system.impermanence = {
    enable = mkEnableOption "system impermanence";
    rootBlankSnapshotName = lib.mkOption {
      type = lib.types.str;
      default = "blank";
    };
    rootPoolName = lib.mkOption {
      type = lib.types.str;
      default = "rpool/local/root";
    };
    persistPath = lib.mkOption {
      type = lib.types.str;
      default = "/persist";
    };
  };

  config = lib.mkIf cfg.enable {
    # Rollback root to blank snapshot after boot
    boot.initrd.postDeviceCommands = lib.mkAfter ''
      zfs rollback -r ${cfg.rootPoolName}@${cfg.rootBlankSnapshotName}
    '';

    # Define persistence paths
    environment.persistence."${cfg.persistPath}" = {
      hideMounts = true;
      directories = [
        "/var/log"          # Persist logs between reboots for debugging
        "/var/lib/cache"    # Cache files (e.g., restic, nginx, containers)
        "/var/lib/nixos"    # NixOS state
        "/var/lib/omada"    # Omada controller data
        "/var/lib/unifi"    # Unifi controller data
      ];
      files = [
        "/etc/machine-id"                # Machine ID
        "/etc/ssh/ssh_host_ed25519_key"  # SSH private key
        "/etc/ssh/ssh_host_ed25519_key.pub"  # SSH public key
        "/etc/ssh/ssh_host_rsa_key"      # RSA private key
        "/etc/ssh/ssh_host_rsa_key.pub"  # RSA public key
      ];
    };

    # Ensure persistence services wait for /persist to mount
    systemd.services."impermanence-bind-mounts" = {
      description = "Ensure impermanence bind mounts are set up";
      wantedBy = [ "local-fs.target" ];
      after = [ "persist.mount" "zfs-mount.service" ];
      requires = [ "persist.mount" "zfs-mount.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Ensure machine-id is correctly symlinked
        if [ ! -e /etc/machine-id ]; then
          ln -sf ${cfg.persistPath}/etc/machine-id /etc/machine-id
        fi
      '';
    };

    # Modify the SSH key permissions service to be more careful
    systemd.services.ssh-key-permissions = {
      description = "Manage SSH host keys for persistence";
      wantedBy = [ "multi-user.target" ];
      after = [ "impermanence-bind-mounts.service" ];
      requires = [ "impermanence-bind-mounts.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # SSH host keys to manage
        ssh_keys=(
          "ssh_host_ed25519_key"
          "ssh_host_ed25519_key.pub"
          "ssh_host_rsa_key"
          "ssh_host_rsa_key.pub"
        )

        # Ensure persist directory exists
        mkdir -p /persist/etc/ssh

        for key in "${ssh_keys[@]}"; do
          persist_key="/persist/etc/ssh/$key"
          system_key="/etc/ssh/$key"

          # Check if the system key is already a symlink to the persist location
          if [ -L "$system_key" ] && [ "$(readlink -f "$system_key")" == "$persist_key" ]; then
            echo "SSH key $key is already correctly symlinked. Skipping."
            continue
          fi

          # If the system key doesn't exist or isn't a symlink to persist
          if [ ! -L "$system_key" ]; then
            # If no existing key in persist, copy the current key
            if [ ! -f "$persist_key" ]; then
              cp -p "$system_key" "$persist_key"
            fi

            # Remove existing file and create symlink
            rm -f "$system_key"
            ln -sf "$persist_key" "$system_key"
          fi

          # Set correct permissions
          if [[ "$key" == *".pub" ]]; then
            chmod 644 "$persist_key"
          else
            chmod 600 "$persist_key"
          fi
        done
      '';
    };

    # Ensure SSH uses the persisted keys
    services.openssh = {
      hostKeys = [
        {
          path = "${cfg.persistPath}/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
        {
          path = "${cfg.persistPath}/etc/ssh/ssh_host_rsa_key";
          type = "rsa";
        }
      ];
    };

    # Tmpfiles rules to ensure machine-id and SSH keys are linked
    systemd.tmpfiles.rules = [
      "L+ /etc/machine-id - - - - ${cfg.persistPath}/etc/machine-id"
      "L+ /etc/ssh/ssh_host_ed25519_key - - - - ${cfg.persistPath}/etc/ssh/ssh_host_ed25519_key"
      "L+ /etc/ssh/ssh_host_ed25519_key.pub - - - - ${cfg.persistPath}/etc/ssh/ssh_host_ed25519_key.pub"
      "L+ /etc/ssh/ssh_host_rsa_key - - - - ${cfg.persistPath}/etc/ssh/ssh_host_rsa_key"
      "L+ /etc/ssh/ssh_host_rsa_key.pub - - - - ${cfg.persistPath}/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };
}
