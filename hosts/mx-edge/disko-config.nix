# One disk: an EFI system partition and an ext4 root. Nothing on this host
# needs snapshots: Stalwart's queue drains to the cluster, and its settings
# are exported with `stalwart-cli snapshot`.
{ disks ? [ "/dev/vda" ], ... }:
{
  disko.devices.disk.sys = {
    device = builtins.elemAt disks 0;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = "512M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
