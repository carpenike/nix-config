{ disks
    # Tip: pass stable by-id paths at run time, e.g.:
    # --arg disks '["/dev/disk/by-id/nvme-SAMSUNG_500GB_ID" "/dev/disk/by-id/nvme-WD_1TB_ID"]'
    ? [ "/dev/nvme0n1" "/dev/nvme1n1" ]
, ... }:

{
  disko.devices = {
    disk = {
      # 500 GB system disk
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

      # 1 TB data disk
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

            # Optional: add a second ESP here if you want dual-bootability on disk #2.
            # ESP2 = {
            #   type = "EF00";
            #   start = "1MiB";
            #   end   = "500MiB";
            #   content = {
            #     type = "filesystem";
            #     format = "vfat";
            #     mountpoint = "/boot2"; # or leave unmounted and copy EFI files later
            #     mountOptions = [ "defaults" ];
            #   };
            # };
          };
        };
      };
    };

    # --- rpool (system) on 500 GB ---
    zpool.rpool = {
      type = "zpool";
      options = {
        ashift = "12";
        autotrim = "on";
      };
      rootFsOptions = {
        mountpoint = "none";
        compression = "lz4";
        relatime    = "on";
        xattr       = "sa";
        acltype     = "posixacl";
        dnodesize   = "auto";
        canmount    = "off";
        normalization = "formD";        # keep for system pool if you like
        redundant_metadata = "most";    # perf/space tradeoff vs 'all'
        "com.sun:auto-snapshot" = "false"; # off at root; enable per-dataset
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
            "com.sun:auto-snapshot" = "false";  # ephemeral root, no autosnaps
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

        "safe" = {
          type = "zfs_fs";
          options.mountpoint = "none";
        };

        "safe/home" = {
          type = "zfs_fs";
          mountpoint = "/home";
          options = {
            mountpoint = "legacy";
            "com.sun:auto-snapshot" = "true";
          };
        };

        "safe/persist" = {
          type = "zfs_fs";
          mountpoint = "/persist";
          options = {
            mountpoint = "legacy";
            "com.sun:auto-snapshot" = "true";
          };
        };
      };
    };

    # --- tank (data) on 1 TB ---
    zpool.tank = {
      type = "zpool";
      options = {
        ashift = "12";
        autotrim = "on";
      };
      rootFsOptions = {
        mountpoint = "none";
        compression = "lz4";
        atime      = "off";
        relatime   = "on";
        xattr      = "sa";
        canmount   = "off";
        # omit normalization for data pool (slightly less metadata work)
        redundant_metadata = "most";
      };

      datasets = {
        # Containers (Docker/Podman)
        "containers" = {
          type = "zfs_fs";
          mountpoint = "/var/lib/containers";
          options = {
            mountpoint = "legacy";
            recordsize = "128K";          # 16K if DB-heavy
            "com.sun:auto-snapshot" = "true";
          };
        };

        # VM images (qcow2/raw files). If you prefer zvols, we can model that too.
        "vm" = {
          type = "zfs_fs";
          mountpoint = "/var/lib/libvirt/images";
          options = {
            mountpoint = "legacy";
            recordsize = "64K";           # match QCOW2 default cluster_size
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

        # Reserve free space so you don't hit the 80–90% cliff
        "dutyfree" = {
          type = "zfs_fs";
          options = {
            mountpoint = "none";
            reservation = "100G"; # adjust to taste
          };
        };

        # Optional: swap on zvol (uncomment if you want swap here)
        # "swap" = {
        #   type = "zfs_volume";
        #   size = "32G";
        #   options = {
        #     volblocksize = "4K";
        #     compression  = "off";
        #     logbias      = "throughput";
        #     primarycache = "metadata";
        #     secondarycache = "none";
        #     "com.sun:auto-snapshot" = "false";
        #   };
        # };
      };
    };
  };

  # Ensure critical mounts are available during boot
  fileSystems."/persist".neededForBoot = true;
  fileSystems."/home".neededForBoot = true;
}
