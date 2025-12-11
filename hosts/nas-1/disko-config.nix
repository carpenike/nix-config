# hosts/nas-1/disko-config.nix
#
# Disko configuration for nas-1 boot drive ONLY.
#
# IMPORTANT: The existing "backup" ZFS pool (RAIDZ1 with 4x14TB HDDs) is NOT
# managed by disko. It will be imported via boot.zfs.extraPools = [ "backup" ];
#
# This disko config only sets up:
# - Boot drive (64GB SSD) with:
#   - ESP partition for UEFI boot
#   - rpool ZFS pool for system (root, nix, persist)
#
# The backup pool must be preserved during NixOS installation:
# 1. Export: zpool export backup
# 2. Install NixOS with this disko config
# 3. Import: boot.zfs.extraPools = [ "backup" ]; handles this automatically
#
# =============================================================================
# Disk Inventory (for reference / disaster recovery)
# =============================================================================
#
# Boot SSD (managed by disko):
#   ata-TS64GMTS600_G016180046 -> sda (64GB Transcend MTS600)
#
# Data HDDs (backup pool - RAIDZ1, NOT managed by disko):
#   ata-ST14000NM001G-2KJ103_ZL23F5FE -> sdb (14TB Seagate Exos)
#   ata-ST14000NM001G-2KJ103_ZL22ZSEB -> sdc (14TB Seagate Exos)
#   ata-ST14000NM001G-2KJ103_ZL22V8LH -> sdd (14TB Seagate Exos)
#   ata-ST14000NM001G-2KJ103_ZL23JYHD -> sde (14TB Seagate Exos)
#
# =============================================================================

{ disks ? [ "/dev/disk/by-id/ata-TS64GMTS600_G016180046" ]  # Boot SSD (64GB Transcend)
, ...
}:

{
  disko.devices = {
    disk = {
      boot = {
        device = builtins.elemAt disks 0;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              type = "EF00";
              start = "1MiB";
              end = "500MiB";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "defaults" ];
              };
            };
            zfs = {
              size = "100%";
              content = { type = "zfs"; pool = "rpool"; };
            };
          };
        };
      };
    };

    zpool = {
      rpool = {
        type = "zpool";
        options = {
          ashift = "12";
          autotrim = "on";
        };
        rootFsOptions = {
          mountpoint = "none";
          compression = "lz4";
          relatime = "on";
          xattr = "sa";
          acltype = "posixacl";
          dnodesize = "auto";
          canmount = "off";
          normalization = "formD";
          "com.sun:auto-snapshot" = "false";
        };

        datasets = {
          "local" = {
            type = "zfs_fs";
            options.mountpoint = "none";
          };

          "local/root" = {
            type = "zfs_fs";
            mountpoint = "/";
            options = {
              mountpoint = "legacy";
              "com.sun:auto-snapshot" = "false";
            };
            postCreateHook = ''
              zfs snapshot rpool/local/root@blank
            '';
          };

          "local/nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options = {
              mountpoint = "legacy";
              atime = "off";
              canmount = "on";
              "com.sun:auto-snapshot" = "false";
            };
          };

          "safe" = {
            type = "zfs_fs";
            options.mountpoint = "none";
          };

          "safe/persist" = {
            type = "zfs_fs";
            mountpoint = "/persist";
            options = {
              mountpoint = "legacy";
              "com.sun:auto-snapshot" = "true";
            };
          };

          "safe/home" = {
            type = "zfs_fs";
            mountpoint = "/home";
            options = {
              mountpoint = "legacy";
              "com.sun:auto-snapshot" = "true";
            };
          };
        };
      };
    };
  };

  # Required for impermanence - these filesystems must be mounted early
  fileSystems."/persist".neededForBoot = true;
  fileSystems."/home".neededForBoot = true;
}
