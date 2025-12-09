# =============================================================================
# Impermanence Module with Contributory Pattern
# =============================================================================
#
# This module implements ZFS root rollback and persistence management using
# the contributory pattern. Services declare their own persistence needs:
#
#   modules.system.impermanence.directories = [ "/var/lib/myservice" ];
#   modules.system.impermanence.files = [ "/etc/myservice.conf" ];
#
# Core system paths (logs, SSH keys, NixOS state) are always persisted.
# Service-specific paths are contributed by individual service modules.
#
# =============================================================================
{ lib
, config
, pkgs
, ...
}:
let
  cfg = config.modules.system.impermanence;
  # Check if systemd stage1 is enabled
  useSystemdInitrd = config.boot.initrd.systemd.enable or false;

  # Type for persistence directory entries (supports both string and attrset forms)
  persistenceDirType = lib.types.either lib.types.str (lib.types.submodule {
    options = {
      directory = lib.mkOption {
        type = lib.types.str;
        description = "Path to the directory to persist";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "Owner user";
      };
      group = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "Owner group";
      };
      mode = lib.mkOption {
        type = lib.types.str;
        default = "0755";
        description = "Directory mode";
      };
    };
  });
in
{
  options.modules.system.impermanence = {
    enable = lib.mkEnableOption "system impermanence";

    rootBlankSnapshotName = lib.mkOption {
      type = lib.types.str;
      default = "blank";
      description = "Name of the blank ZFS snapshot to rollback to on boot";
    };

    rootPoolName = lib.mkOption {
      type = lib.types.str;
      default = "rpool/local/root";
      description = "ZFS dataset path for the root filesystem";
    };

    persistPath = lib.mkOption {
      type = lib.types.str;
      default = "/persist";
      description = "Path where persistent data is stored";
    };

    # =========================================================================
    # Contributory options - services add their paths here
    # =========================================================================

    directories = lib.mkOption {
      type = lib.types.listOf persistenceDirType;
      default = [ ];
      example = lib.literalExpression ''
        [
          "/var/lib/myservice"
          { directory = "/var/lib/postgres"; user = "postgres"; group = "postgres"; mode = "0750"; }
        ]
      '';
      description = ''
        Directories to persist across reboots.

        Services should contribute their persistence paths here:
          modules.system.impermanence.directories = [ "/var/lib/myservice" ];

        For directories requiring specific ownership:
          modules.system.impermanence.directories = [{
            directory = "/var/lib/myservice";
            user = "myservice";
            group = "myservice";
            mode = "0750";
          }];
      '';
    };

    files = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/etc/myservice.conf" ];
      description = ''
        Individual files to persist across reboots.

        Services should contribute their persistence paths here:
          modules.system.impermanence.files = [ "/etc/myservice.conf" ];
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # =========================================================================
    # Core system persistence paths (always needed)
    # =========================================================================

    modules.system.impermanence.directories = [
      "/var/log" # Persist logs between reboots for debugging
      "/var/lib/cache" # Cache files (e.g., restic, nginx, containers)
      "/var/lib/nixos" # NixOS state (uid/gid maps, etc.)
    ];

    modules.system.impermanence.files = [
      # SSH keys are persisted via files option
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];

    # =========================================================================
    # ZFS rollback configuration
    # =========================================================================

    # Rollback root to blank snapshot during initrd
    # Support both legacy and systemd stage1 initrd
    boot.initrd.postDeviceCommands = lib.mkIf (!useSystemdInitrd) (lib.mkAfter ''
      zfs rollback -r ${cfg.rootPoolName}@${cfg.rootBlankSnapshotName}
    '');

    # Systemd stage1 rollback service (used when boot.initrd.systemd.enable = true)
    boot.initrd.systemd.services.rollback = lib.mkIf useSystemdInitrd {
      description = "Rollback ZFS root to blank snapshot";
      wantedBy = [ "initrd.target" ];
      after = [ "zfs-import-rpool.service" ];
      before = [ "sysroot.mount" ];
      path = [ config.boot.zfs.package ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      script = ''
        zfs rollback -r ${cfg.rootPoolName}@${cfg.rootBlankSnapshotName}
      '';
    };

    # =========================================================================
    # Persistence configuration (aggregates all contributions)
    # =========================================================================

    environment.persistence."${cfg.persistPath}" = {
      hideMounts = true;
      directories = cfg.directories;
      files = cfg.files;
    };

    # =========================================================================
    # Machine-ID handling
    # =========================================================================

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

    # =========================================================================
    # SSH configuration
    # =========================================================================

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

    # Tmpfiles rules to ensure SSH keys are linked
    systemd.tmpfiles.rules = [
      "L+ /etc/ssh/ssh_host_ed25519_key - - - - ${cfg.persistPath}/etc/ssh/ssh_host_ed25519_key"
      "L+ /etc/ssh/ssh_host_ed25519_key.pub - - - - ${cfg.persistPath}/etc/ssh/ssh_host_ed25519_key.pub"
      "L+ /etc/ssh/ssh_host_rsa_key - - - - ${cfg.persistPath}/etc/ssh/ssh_host_rsa_key"
      "L+ /etc/ssh/ssh_host_rsa_key.pub - - - - ${cfg.persistPath}/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };
}
