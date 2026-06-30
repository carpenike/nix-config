{ ... }:
let
  persistDisk = "/dev/disk/by-id/usb-SABRENT_ASM1153E_0000000000B7-0:0";
in
{
  disko.devices.disk.persist = {
    device = persistDisk;
    type = "disk";
    content = {
      type = "gpt";
      partitions.persist = {
        size = "100%";
        content = {
          type = "btrfs";
          extraArgs = [ "-f" "-L" "NIXPI_PERSIST" ];
          subvolumes = {
            "@persist" = {
              mountpoint = "/persist";
              mountOptions = [ "compress=zstd" "noatime" "nofail" ];
            };
            "@var_log" = {
              mountpoint = "/var/log";
              mountOptions = [ "compress=zstd" "nofail" ];
            };
            "@var_cache" = {
              mountpoint = "/var/cache";
              mountOptions = [ "compress=zstd" "nofail" ];
            };
            "@coachiq" = {
              mountpoint = "/var/lib/coachiq";
              mountOptions = [ "compress=zstd" "noatime" "nofail" ];
            };
          };
        };
      };
    };
  };
}
