# hosts/nas-0/disko-config.nix
#
# Disko configuration for nas-0 boot disk ONLY
#
# IMPORTANT: This only configures the boot SSD (rpool).
# The tank pool (14 mirror vdevs, 117TB) is IMPORTED separately via
# boot.zfs.extraPools - it is NOT managed by disko.
#
# =============================================================================
# DISK INVENTORY (for disaster recovery reference)
# =============================================================================
#
# Boot SSD:
#   ada0: TS64GMTS600 (64GB) - Serial: G016180039
#         NixOS: /dev/disk/by-id/ata-TS64GMTS600_G016180039
#
# Tank Pool (14 mirror vdevs - DO NOT INCLUDE IN DISKO):
#   These are managed by ZFS and imported via boot.zfs.extraPools
#
#   mirror-0:  WDC WD120EMFZ + Hitachi HUS72403
#   mirror-1:  WDC WD120EMAZ + (pair)
#   mirror-2:  (pair)
#   mirror-3:  (pair)
#   mirror-4:  (pair)
#   mirror-5:  (pair)
#   mirror-6:  ST16000NM001G × 2
#   mirror-7:  ST18000NM000J × 2
#   mirror-8:  (pair)
#   mirror-9:  (pair)
#   mirror-10: (pair)
#   mirror-11: (pair)
#   mirror-12: ST20000NM007D × 2
#   mirror-13: ST20000NM007D × 2
#
# =============================================================================

{ disks ? [ "/dev/disk/by-id/ata-TS64GMTS600_G016180039" ], ... }:

{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = builtins.elemAt disks 0;
        content = {
          type = "gpt";
          partitions = {
            # EFI System Partition
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };

            # ZFS partition for rpool (boot pool)
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "rpool";
              };
            };
          };
        };
      };
    };

    # ZFS pool configuration (boot pool only)
    zpool = {
      rpool = {
        type = "zpool";
        # Single disk, no redundancy (boot data only)
        # Critical data is on tank pool with mirrors

        rootFsOptions = {
          compression = "zstd";
          acltype = "posixacl";
          xattr = "sa";
          atime = "off";
          mountpoint = "none";
          canmount = "off";
          "com.sun:auto-snapshot" = "false";
        };

        options = {
          ashift = "12";
          autotrim = "on";
        };

        datasets = {
          # Local datasets (wiped on reboot)
          "local" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              canmount = "off";
            };
          };

          "local/root" = {
            type = "zfs_fs";
            mountpoint = "/";
            options = {
              mountpoint = "legacy";
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
            };
          };

          # Safe datasets (persist across reboots)
          "safe" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              canmount = "off";
            };
          };

          "safe/persist" = {
            type = "zfs_fs";
            mountpoint = "/persist";
            options = {
              mountpoint = "legacy";
            };
          };

          "safe/home" = {
            type = "zfs_fs";
            mountpoint = "/home";
            options = {
              mountpoint = "legacy";
            };
          };
        };
      };
    };
  };

  # Ensure /persist and /home are available early for impermanence
  fileSystems."/persist".neededForBoot = true;
  fileSystems."/home".neededForBoot = true;
}
