{ lib
, disks ? [ "/dev/nvme0n1" ]
, ...
}:

let
  haveTwo = (builtins.length disks) >= 2;
in
{
  disko.devices = {
    disk =
      {
        sys = {
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
      }
      // lib.optionalAttrs haveTwo {
        data = {
          device = builtins.elemAt disks 1;
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              zfs = {
                size = "100%";
                content = { type = "zfs"; pool = "tank"; };
              };
            };
          };
        };
      };

    zpool = {
      # rpool always present
      rpool = {
        type = "zpool";
        options = { ashift = "12"; autotrim = "on"; };
        rootFsOptions = {
          mountpoint = "none";
          compression = "lz4";
          relatime = "on";
          xattr = "sa";
          acltype = "posixacl";
          dnodesize = "auto";
          canmount = "off";
          normalization = "formD";
          redundant_metadata = "most";
        };

        datasets =
          {
            "local" = { type = "zfs_fs"; options.mountpoint = "none"; };

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
                canmount = "on";
              };
            };

            "safe" = { type = "zfs_fs"; options.mountpoint = "none"; };

            "safe/home" = {
              type = "zfs_fs";
              mountpoint = "/home";
              options = { mountpoint = "legacy"; };
            };

            "safe/persist" = {
              type = "zfs_fs";
              mountpoint = "/persist";
              options = {
                mountpoint = "legacy";
              };
            };
          }
          // lib.optionalAttrs (!haveTwo) {
            # Single-disk: put apps on rpool
            "apps" = { type = "zfs_fs"; options.mountpoint = "none"; };

            "apps/containers" = {
              type = "zfs_fs";
              mountpoint = "/var/lib/containers";
              options = {
                mountpoint = "legacy";
                recordsize = "128K";
              };
            };

            "apps/vm" = {
              type = "zfs_fs";
              mountpoint = "/var/lib/libvirt/images";
              options = {
                mountpoint = "legacy";
                recordsize = "64K";
              };
            };

            # REMOVED: rpool/apps/media - now using NFS mount at /mnt/data instead
            # "apps/media" = {
            #   type = "zfs_fs";
            #   mountpoint = "/srv/media";
            #   options = {
            #     mountpoint = "legacy";
            #     recordsize = "1M";
            #   };
            # };

            "apps/backups" = {
              type = "zfs_fs";
              mountpoint = "/srv/backups";
              options = {
                mountpoint = "legacy";
                recordsize = "1M";
              };
            };

            # Reserve space on single-disk
            "apps/dutyfree" = {
              type = "zfs_fs";
              options = {
                mountpoint = "none";
                reservation = "50G"; # ~10% of 500GB
              };
            };
          }
          // lib.optionalAttrs haveTwo {
            # Two-disk: rpool only holds system datasets, but a full rpool still
            # wedges the host (CoW needs free space to delete). Mirror the tank
            # dutyfree pattern with a small unmounted reservation.
            # NOTE: disko only runs at provisioning time. On the live host this
            # must be created manually:
            #   zfs create -o mountpoint=none -o reservation=15G rpool/dutyfree
            "dutyfree" = {
              type = "zfs_fs";
              options = {
                mountpoint = "none";
                reservation = "15G";
              };
            };
          };
      };
    } // lib.optionalAttrs haveTwo {
      # Two-disk: separate tank pool
      tank = {
        type = "zpool";
        options = { ashift = "12"; autotrim = "on"; };
        rootFsOptions = {
          mountpoint = "none";
          compression = "lz4";
          atime = "off";
          xattr = "sa";
          canmount = "off";
          redundant_metadata = "most";
        };

        datasets = {
          # Parent dataset for managed service data.
          # Not mounted itself; children are mounted to FHS paths.
          "services" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
            };
          };

          "containers" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/containers";
            options = {
              mountpoint = "legacy";
              recordsize = "128K";
            };
          };

          "vm" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/libvirt/images";
            options = {
              mountpoint = "legacy";
              recordsize = "64K";
            };
          };

          # REMOVED: tank/media - now using NFS mount at /mnt/data instead
          # "media" = {
          #   type = "zfs_fs";
          #   mountpoint = "/srv/media";
          #   options = {
          #     mountpoint = "legacy";
          #     recordsize = "1M";
          #   };
          # };

          "backups" = {
            type = "zfs_fs";
            mountpoint = "/srv/backups";
            options = {
              mountpoint = "legacy";
              recordsize = "1M";
            };
          };

          "dutyfree" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              reservation = "100G"; # ~10% of 1TB
            };
          };
        };
      };
    };
  };

  fileSystems."/persist".neededForBoot = true;
  fileSystems."/home".neededForBoot = true;
}
