{ disks ? [ "/dev/sda" ], ... }: {
  disko.devices = {
    disk = {
      vdb = {
        device = builtins.elemAt disks 0;
        type = "disk";
        content = {
          type = "table";
          format = "gpt";
          partitions = [
            {
              name = "ESP";
              start = "1M";
              end = "500M";
              bootable = true;
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "defaults"
                ];
              };
            }
            {
              name = "zfs";
              start = "500M";
              end = "100%";
              content = {
                type = "zfs";
                pool = "rpool";
              };
            }
          ];
        };
      };
    };
    zpool = {
      zroot = {
        type = "rpool";
        rootFsOptions = {
          compression = "zstd";
        };
        mountpoint = "/";
        postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^rpool@blank$' || zfs snapshot rpool@blank";

        datasets = {
          "rpool/local/root" = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
          };
          "rpool/local/nix" = {
            type = "zfs_fs";
            options.mountpoint = "/nix";
          };
          "rpool/safe/home" = {
            type = "zfs_fs";
            options.mountpoint = "/home";
          };
          "rpool/safe/persist" = {
            type = "zfs_fs";
            options.mountpoint = "/persist";
          };
        };
      };
    };
  };
}
