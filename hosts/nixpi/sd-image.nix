# SD-image variant for nixpi: produces an image that boots DIRECTLY as the
# finished tmpfs-root appliance — no convergence deploy. Future upgrades:
# rebuild image, reflash, insert; all state lives on the USB SSD /persist.
#   nix build .#nixosConfigurations.nixpi-image.config.system.build.sdImage
{ lib, pkgs, modulesPath, ... }:
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
  };

  # Appliance layout: tmpfs root, store on the SD (label NIXOS_SD) at /nix,
  # firmware on FAT, all state on the USB SSD. mkForce over the sd-image default
  # ext4-root so the flashed image is the final appliance.
  fileSystems = lib.mkForce {
    "/" = { device = "none"; fsType = "tmpfs"; options = [ "defaults" "size=2G" "mode=755" ]; };
    "/nix" = { device = "/dev/disk/by-label/NIXOS_SD"; fsType = "ext4"; options = [ "noatime" ]; neededForBoot = true; };
    "/boot" = { device = "/dev/disk/by-label/FIRMWARE"; fsType = "vfat"; };
    "/persist" = {
      device = "/dev/disk/by-id/usb-SABRENT_ASM1153E_0000000000B7-0:0-part1";
      fsType = "btrfs";
      options = [ "subvol=@persist" "compress=zstd" "noatime" "nofail" ];
      neededForBoot = true;
    };
  };

  # First boot: create the @persist subvol on the SSD if missing so impermanence
  # has its target; then nothing else needs setup.
  systemd.services.nixpi-persist-bootstrap = {
    description = "Create @persist subvol on the USB SSD if missing";
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.util-linux pkgs.btrfs-progs pkgs.coreutils ];
    script = ''
      dev=/dev/disk/by-id/usb-SABRENT_ASM1153E_0000000000B7-0:0-part1
      [ -e "$dev" ] || exit 0
      mp=$(mktemp -d); mount "$dev" "$mp" || exit 0
      btrfs subvolume show "$mp/@persist" >/dev/null 2>&1 || btrfs subvolume create "$mp/@persist"
      umount "$mp"; rmdir "$mp" || true
    '';
  };
}
