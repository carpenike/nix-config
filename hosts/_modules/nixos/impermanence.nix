{ lib
, config
, pkgs
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
        "/var/log" # Persist logs between reboots for debugging
        "/var/lib/cache" # Cache files (e.g., restic, nginx, containers)
        "/var/lib/nixos" # NixOS state
        "/var/lib/omada" # Omada controller data
        "/var/lib/unifi" # Unifi controller data
        # Persist Caddy's ACME certificates to avoid Let's Encrypt rate limiting
        # during frequent rebuilds/DR testing. Caddy still handles automatic renewal.
        # This also ensures TLS metrics are immediately available on boot.
        {
          directory = "/var/lib/caddy";
          user = "caddy";
          group = "caddy";
          mode = "0750";
        }
      ];
      files = [
        # Machine-id is handled by tmpfiles.rules as a symlink, not persisted directly
        "/etc/ssh/ssh_host_ed25519_key" # SSH private key
        "/etc/ssh/ssh_host_ed25519_key.pub" # SSH public key
        "/etc/ssh/ssh_host_rsa_key" # RSA private key
        "/etc/ssh/ssh_host_rsa_key.pub" # RSA public key
      ];
    };

    # Handle machine-id setup in activation script (runs early in boot)
    system.activationScripts.persistMachineId = lib.stringAfter [ "etc" ] ''
      # Ensure persist directory structure exists
      mkdir -p ${cfg.persistPath}/etc

      # Handle machine-id carefully to avoid data loss
      if [ ! -e ${cfg.persistPath}/etc/machine-id ]; then
        if [ -e /etc/machine-id ] && [ ! -L /etc/machine-id ]; then
          # Preserve existing machine-id
          echo "Moving existing machine-id to persist location..."
          cp /etc/machine-id ${cfg.persistPath}/etc/machine-id
        else
          # Generate new machine-id in persist location
          echo "Generating new machine-id..."
          ${pkgs.systemd}/bin/systemd-machine-id-setup --print > ${cfg.persistPath}/etc/machine-id
        fi
      fi

      # Create symlink if it doesn't exist or is wrong
      if [ ! -L /etc/machine-id ] || [ "$(readlink /etc/machine-id)" != "${cfg.persistPath}/etc/machine-id" ]; then
        # Remove existing file/link safely
        if [ -e /etc/machine-id ] || [ -L /etc/machine-id ]; then
          rm -f /etc/machine-id
        fi
        ln -s ${cfg.persistPath}/etc/machine-id /etc/machine-id
      fi
    '';

    # SSH key management is handled by systemd.tmpfiles.rules and impermanence
    # Remove the conflicting service that tries to manage the same files
    systemd.services.ssh-key-permissions = lib.mkForce { };

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

    # Tmpfiles rules to ensure SSH keys are linked (but NOT machine-id, handled separately)
    systemd.tmpfiles.rules = [
      # SSH keys can be safely force-linked as they're generated at a known time
      "L+ /etc/ssh/ssh_host_ed25519_key - - - - ${cfg.persistPath}/etc/ssh/ssh_host_ed25519_key"
      "L+ /etc/ssh/ssh_host_ed25519_key.pub - - - - ${cfg.persistPath}/etc/ssh/ssh_host_ed25519_key.pub"
      "L+ /etc/ssh/ssh_host_rsa_key - - - - ${cfg.persistPath}/etc/ssh/ssh_host_rsa_key"
      "L+ /etc/ssh/ssh_host_rsa_key.pub - - - - ${cfg.persistPath}/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };
}
