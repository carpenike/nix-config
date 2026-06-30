# SD-image variant for nixpi: produces an image that boots DIRECTLY as the
# finished tmpfs-root appliance — no convergence deploy. Future upgrades:
# rebuild image, reflash, insert; all state lives on the USB SSD /persist.
#   nix build .#nixosConfigurations.nixpi-image.config.system.build.sdImage
{ lib, modulesPath, ... }:
{
  imports = [ "${modulesPath}/installer/sd-card/sd-image-aarch64.nix" ];
  disabledModules = [ ./hardware-configuration.nix ];

  # The RPi downstream kernel lacks some generic modules referenced by the
  # sd-image base profile (e.g. dw-hdmi), which aborts modules-shrunk. Tolerate
  # missing modules during the closure build (proven pattern from rv-nixpi).
  nixpkgs.overlays = [
    (_final: super: {
      makeModulesClosure = args: super.makeModulesClosure (args // { allowMissing = true; });
    })
  ];

  sdImage = {
    firmwareSize = 512; # MiB — up from the 30 default; holds the 36 MB kernel
    compressImage = false; # flash result/sd-image/*.img directly
    expandOnBoot = false; # / is tmpfs, so the stock root-partition grow script is wrong here
    nixPathRegistrationFile = "/nix/nix-path-registration";
    populateRootCommands = lib.mkAfter ''
      # The stock SD rootfs image stores closure paths under /nix/store. This
      # appliance mounts that partition at /nix, so create a top-level /store
      # mountpoint. Stage 1 bind-mounts /nix/nix/store over runtime /nix/store.
      mkdir -p ./files/store
    '';
  };

  # Appliance layout: tmpfs root, store on the SD (label NIXOS_SD) at /nix,
  # firmware on FAT, all state on the USB SSD. mkForce over the sd-image default
  # ext4-root so the flashed image is the final appliance.
  fileSystems = lib.mkForce {
    "/" = { device = "none"; fsType = "tmpfs"; options = [ "defaults" "size=2G" "mode=755" ]; };
    "/nix" = { device = "/dev/disk/by-label/NIXOS_SD"; fsType = "ext4"; options = [ "noatime" ]; neededForBoot = true; };
    "/nix/store" = {
      device = "/nix/nix/store";
      fsType = "none";
      options = [ "bind" "ro" "nosuid" "nodev" "noatime" ];
      neededForBoot = true;
      depends = [ "/nix" ];
    };
    "/boot" = { device = "/dev/disk/by-label/FIRMWARE"; fsType = "vfat"; };
    "/persist" = {
      device = "/dev/disk/by-id/usb-SABRENT_ASM1153E_0000000000B7-0:0-part1";
      fsType = "btrfs";
      options = [ "subvol=@persist" "compress=zstd" "noatime" "nofail" ];
      neededForBoot = true;
    };
    "/var/log" = {
      device = "/dev/disk/by-id/usb-SABRENT_ASM1153E_0000000000B7-0:0-part1";
      fsType = "btrfs";
      options = [ "subvol=@var_log" "compress=zstd" "nofail" ];
      neededForBoot = true;
    };
    "/var/cache" = {
      device = "/dev/disk/by-id/usb-SABRENT_ASM1153E_0000000000B7-0:0-part1";
      fsType = "btrfs";
      options = [ "subvol=@var_cache" "compress=zstd" "nofail" ];
      neededForBoot = true;
    };
    "/var/lib/coachiq" = {
      device = "/dev/disk/by-id/usb-SABRENT_ASM1153E_0000000000B7-0:0-part1";
      fsType = "btrfs";
      options = [ "subvol=@coachiq" "compress=zstd" "noatime" "nofail" ];
      neededForBoot = true;
    };
  };
}
