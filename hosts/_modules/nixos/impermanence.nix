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
      after = [ "persist.mount" ];
      requires = [ "persist.mount" ];
    };
  };
}
