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
      rpool = {
        type = "zpool";
        rootFsOptions = {
          compression = "zstd";
        };
        mountpoint = "/";
        postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^rpool@blank$' || zfs snapshot rpool@blank";

        datasets = {
          "local" = {
            type = "zfs_fs";
            options.mountpoint = "none";
          };
          "local/root" = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
          };
          "local/nix" = {
            type = "zfs_fs";
            options.mountpoint = "/nix";
          };
          "safe" = {
            type = "zfs_fs";
            options.mountpoint = "none";
          };
          "safe/home" = {
            type = "zfs_fs";
            options.mountpoint = "/home";
          };
          "safe/persist" = {
            type = "zfs_fs";
            options.mountpoint = "/persist";
          };
        };
      };
    };
  };
}
