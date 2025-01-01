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

    # Ensure SSH keys are correctly linked and have correct permissions
    systemd.services.ssh-key-permissions = {
      description = "Set correct permissions for persisted SSH host keys";
      wantedBy = [ "multi-user.target" ];
      after = [ "impermanence-bind-mounts.service" ];
      requires = [ "impermanence-bind-mounts.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        chmod 600 ${cfg.persistPath}/etc/ssh/ssh_host_*_key
        chmod 644 ${cfg.persistPath}/etc/ssh/ssh_host_*_key.pub
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

    # Additional tmpfiles rule to ensure machine-id is always linked
    systemd.tmpfiles.rules = [
      "L+ /etc/machine-id - - - - ${cfg.persistPath}/etc/machine-id"
    ];
  };
}
