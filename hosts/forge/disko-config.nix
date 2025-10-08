{ lib
, disks ? [ "/dev/nvme0n1" ]
, ... }:

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
                end   = "500MiB";
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
          relatime    = "on";
          xattr       = "sa";
          acltype     = "posixacl";
          dnodesize   = "auto";
          canmount    = "off";
          normalization = "formD";
          redundant_metadata = "most";
          "com.sun:auto-snapshot" = "false";
        };

        datasets =
          {
            "local" = { type = "zfs_fs"; options.mountpoint = "none"; };

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
                atime      = "off";
                canmount   = "on";
                "com.sun:auto-snapshot" = "true";
              };
            };

            "safe" = { type = "zfs_fs"; options.mountpoint = "none"; };

            "safe/home" = {
              type = "zfs_fs";
              mountpoint = "/home";
              options = { mountpoint = "legacy"; "com.sun:auto-snapshot" = "true"; };
            };

            "safe/persist" = {
              type = "zfs_fs";
              mountpoint = "/persist";
              options = { mountpoint = "legacy"; "com.sun:auto-snapshot" = "true"; };
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
                "com.sun:auto-snapshot" = "true";
              };
            };

            "apps/vm" = {
              type = "zfs_fs";
              mountpoint = "/var/lib/libvirt/images";
              options = {
                mountpoint = "legacy";
                recordsize = "64K";
                "com.sun:auto-snapshot" = "true";
              };
            };

            "apps/media" = {
              type = "zfs_fs";
              mountpoint = "/srv/media";
              options = {
                mountpoint = "legacy";
                recordsize = "1M";
                "com.sun:auto-snapshot" = "true";
              };
            };

            "apps/backups" = {
              type = "zfs_fs";
              mountpoint = "/srv/backups";
              options = {
                mountpoint = "legacy";
                recordsize = "1M";
                "com.sun:auto-snapshot" = "true";
              };
            };

            # Reserve space on single-disk
            "apps/dutyfree" = {
              type = "zfs_fs";
              options = {
                mountpoint  = "none";
                reservation = "50G";  # ~10% of 500GB
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
          atime      = "off";
          xattr      = "sa";
          canmount   = "off";
          redundant_metadata = "most";
        };

        datasets = {
          "containers" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/containers";
            options = {
              mountpoint = "legacy";
              recordsize = "128K";
              "com.sun:auto-snapshot" = "true";
            };
          };

          "vm" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/libvirt/images";
            options = {
              mountpoint = "legacy";
              recordsize = "64K";
              "com.sun:auto-snapshot" = "true";
            };
          };

          "media" = {
            type = "zfs_fs";
            mountpoint = "/srv/media";
            options = {
              mountpoint = "legacy";
              recordsize = "1M";
              "com.sun:auto-snapshot" = "true";
            };
          };

          "backups" = {
            type = "zfs_fs";
            mountpoint = "/srv/backups";
            options = {
              mountpoint = "legacy";
              recordsize = "1M";
              "com.sun:auto-snapshot" = "true";
            };
          };

          "dutyfree" = {
            type = "zfs_fs";
            options = {
              mountpoint  = "none";
              reservation = "100G";  # ~10% of 1TB
            };
          };
        };
      };
    };
  };

  fileSystems."/persist".neededForBoot = true;
  fileSystems."/home".neededForBoot = true;
}
