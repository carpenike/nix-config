{ lib, ... }:
{
  options.modules.storage.preseed = {
    enable = lib.mkEnableOption "global pre-seed of ZFS-backed storage (default-on)" // { default = true; };

    restoreMethods = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
      default = [ "syncoid" "local" "restic" ];
      description = "Order of restore methods attempted during pre-seed.";
    };

    repositoryUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Restic repository URL for system-level preseed (optional). If null, tries first configured repository if any.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to Restic password file for system-level preseed (optional).";
    };

    # paths option removed; default system paths (/persist, /home) are handled automatically
  };

  # Avoid referencing `config` here entirely to remove any possibility of
  # recursive evaluation. The target is harmless when present; services can
  # attach to it conditionally in their own modules.
  config = {
    systemd.targets.storage-preseed = {
      description = "Storage Preseed (restore persistent data before services)";
      wantedBy = [ "multi-user.target" ];
      after = [ "zfs-import.target" "zfs-mount.service" "systemd-tmpfiles-setup.service" ];
    };
  };
}
