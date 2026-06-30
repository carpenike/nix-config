{ lib, pkgs, ... }:
{
  # Temporary filesystems to reduce SD card wear
  fileSystems."/tmp" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "nosuid" "nodev" "mode=1777" ];
  };

  fileSystems."/var/tmp" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "nosuid" "nodev" "mode=1777" ];
  };
  # The USB SSD layout is owned by disko-config.nix. Mark /persist as an
  # initrd mount because impermanence needs it before stage 2. The other SSD
  # subvolumes also mount in initrd so scripted stage 1 creates mountpoints on
  # the otherwise-empty tmpfs root before systemd starts.
  fileSystems."/persist".neededForBoot = lib.mkDefault true;
  fileSystems."/var/cache".neededForBoot = lib.mkDefault true;
  fileSystems."/var/lib/coachiq".neededForBoot = lib.mkDefault true;

  # Grow the Nix store partition to fill the SD card on first boot.
  #
  # The SD image bakes NIXOS_SD at just store-size + a small margin (~10G), and
  # the stock `sdImage.expandOnBoot` can't help because it resizes the partition
  # backing `/` — which is tmpfs here. So we grow the NIXOS_SD (/nix) partition
  # ourselves, once, using the online-safe recipe (sfdisk --no-reread keeps the
  # mounted fs; partx -u refreshes the kernel; resize2fs grows ext4 live).
  #
  # Idempotent: gated by a marker on /nix itself (NOT /persist), so a fresh
  # reflash — which lands a new 10G NIXOS_SD with no marker — re-runs the grow,
  # while normal boots skip it.
  systemd.services.grow-nix-store-partition = {
    description = "Grow the NIXOS_SD (/nix) partition to fill the SD card";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    unitConfig.ConditionPathExists = "!/nix/.partition-grown";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.util-linux pkgs.e2fsprogs pkgs.gnugrep pkgs.coreutils ];
    script = ''
      set -eu
      part=$(readlink -f /dev/disk/by-label/NIXOS_SD)
      disk="/dev/$(lsblk -no PKNAME "$part" | head -n1)"
      num=$(printf '%s' "$part" | grep -o '[0-9]*$')
      if [ -n "$disk" ] && [ -n "$num" ]; then
        # Extend the last partition into any free space (no-op once it fills the disk).
        echo ", +" | sfdisk --no-reread -N "$num" "$disk" || true
        partx -u "$disk" || true
        resize2fs "$part" || true
      fi
      touch /nix/.partition-grown
    '';
  };
}
