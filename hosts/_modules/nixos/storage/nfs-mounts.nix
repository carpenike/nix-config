# /hosts/_modules/nixos/storage/nfs-mounts.nix
{ lib, config, ... }:
# Declarative NFS mount management.
#
# This module allows defining named NFS mounts that can be reused across hosts.
# It automatically generates the necessary `fileSystems` entries and systemd units.
#
# Service modules can declare a dependency on a mount by its name, and this
# module will ensure the correct systemd `requires` and `after` dependencies
# are added to the service unit.
let
  cfg = config.modules.storage.nfsMounts;

  # Helper to generate the systemd mount unit name from a path
  # e.g., /srv/media -> srv-media.mount
  # systemd.mount units use escaped paths: /mnt/media becomes mnt-media.mount
  getMountUnitName = path:
    let
      # Remove leading slash and replace / with -
      escaped = lib.replaceStrings ["/"] ["-"] (lib.removePrefix "/" path);
    in
    "${escaped}.mount";

  escape = lib.escapeShellArg;
in
{
  options.modules.storage.nfsMounts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
      options = {
        enable = lib.mkEnableOption "this NFS mount";

        server = lib.mkOption {
          type = lib.types.str;
          description = "Hostname or IP address of the NFS server.";
          example = "nas.holthome.net";
        };

        remotePath = lib.mkOption {
          type = lib.types.str;
          description = "The absolute path of the share on the NFS server.";
          example = "/mnt/tank/share";
        };

        localPath = lib.mkOption {
          type = lib.types.str;
          description = "The absolute path for the local mount point.";
          example = "/srv/media";
        };

        mountOptions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "nfsvers=4.2" "rw" "noatime" ];
          description = "A list of NFS mount options.";
          example = [ "ro" "soft" ];
        };

        automount = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable systemd automount for this NFS share.";
        };

        idleTimeout = lib.mkOption {
          type = lib.types.str;
          default = "10min";
          description = "Idle timeout for systemd automounts.";
        };

        mountTimeout = lib.mkOption {
          type = lib.types.str;
          default = "30s";
          description = "Mount timeout for systemd automounts.";
        };

        owner = lib.mkOption {
          type = lib.types.str;
          default = "root";
          description = "User to own the mount point directory.";
        };

        group = lib.mkOption {
          type = lib.types.str;
          default = "root";
          description = "Group to own the mount point directory.";
        };

        mode = lib.mkOption {
          type = lib.types.str;
          default = "0755";
          description = "Permission mode for the mount point directory.";
        };

        # Internal option to expose the generated systemd unit name for dependencies
        mountUnitName = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
          description = "The systemd mount unit name derived from localPath.";
          default = getMountUnitName config.localPath;
        };
      };
    }));
    default = {};
    description = "Declarative definitions for shared NFS mounts.";
    example = lib.literalExpression ''
      {
        media = {
          enable = true;
          server = "nas.holthome.net";
          remotePath = "/mnt/tank/share";
          localPath = "/srv/media";
          group = "media";
          mode = "0775";
        };
      }
    '';
  };

  config = {
    # Generate fileSystems entries ONLY for automounted shares.
    # This leverages NixOS's native support for generating .automount and .mount units.
    fileSystems = lib.mkMerge (lib.mapAttrsToList (name: mount:
      lib.mkIf (mount.enable && mount.automount) {
        "${mount.localPath}" = {
          device = "${mount.server}:${mount.remotePath}";
          fsType = "nfs";
          options = mount.mountOptions ++ [
            "x-systemd.automount"
            "x-systemd.idle-timeout=${mount.idleTimeout}"
            "x-systemd.mount-timeout=${mount.mountTimeout}"
          ];
        };
      }) cfg);

    # Generate static systemd.mount units for non-automounted shares.
    # This is more robust for "always-on" mounts, as it ensures the unit file
    # exists during `nixos-rebuild switch`, preventing activation failures when
    # other services depend on the mount.
    systemd.mounts = lib.mapAttrsToList (name: mount:
      lib.nameValuePair mount.mountUnitName (lib.mkIf (mount.enable && !mount.automount) {
        description = "NFS mount for ${name} at ${mount.localPath}";
        what = "${mount.server}:${mount.remotePath}";
        where = mount.localPath;
        type = "nfs";
        # Options must be a comma-separated string for systemd units.
        options = lib.concatStringsSep "," mount.mountOptions;
        # Ensure the mount is attempted only after the network is available.
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        # Enable the mount unit to start at boot.
        wantedBy = [ "multi-user.target" ];
        # Prevent boot hangs if the NFS server is unreachable.
        mountConfig.TimeoutSec = mount.mountTimeout;
      })) cfg;

    systemd.tmpfiles.rules = lib.flatten (lib.mapAttrsToList (name: mount:
      lib.optional mount.enable
        # Create the mount point directory before systemd tries to mount it
        "d ${escape mount.localPath} ${mount.mode} ${mount.owner} ${mount.group} - -"
    ) cfg);

    assertions = lib.mapAttrsToList (name: mount: {
      assertion = !mount.enable || (lib.hasPrefix "/" mount.localPath);
      message = "NFS mount '${name}': localPath must be an absolute path.";
    }) cfg;
  };
}
