{ lib, ... }:

{
  # Boot loader configuration
  boot.loader = {
    systemd-boot = {
      enable = true;
      # Cap boot entries kept on the ~500MB ESP. Daily auto-upgrades create a
      # generation almost every day; without a limit the ESP fills with old
      # kernels/initrds and upgrades start failing with "No space left on device".
      configurationLimit = 10;
    };
    efi.canTouchEfiVariables = true;
  };

  # ZFS configuration for boot
  # Note: forceImportRoot and other ZFS settings are in _modules/nixos/filesystems/zfs

  # Ensure ZFS is supported in initrd
  boot.supportedFilesystems = [ "zfs" ];

  # Cap ZFS ARC to 8GB (default is all RAM = 32GB)
  # Forge runs 60+ services that need memory; uncapped ARC competes with them
  # and contributed to OOM kills (Plex, Paperless-AI celery worker)
  boot.kernelParams = [
    "zfs.zfs_arc_max=8589934592" # 8GB ARC max (25% of 32GB RAM)
  ];

  # zram compressed swap — OOM safety net
  # Forge has no disk swap; with 60+ services on 32GB RAM, OOM kills are frequent.
  # zram provides ~4GB effective swap in compressed memory without disk I/O pressure on rpool.
  zramSwap = {
    enable = true;
    memoryPercent = 25; # 25% of 32GB = ~8GB zram device, ~4GB effective with compression
    algorithm = "zstd";
  };

  # systemd-oomd — userspace OOM killer that acts BEFORE the kernel OOM killer.
  # With zram swap enabled, swap fill is an early and reliable signal of memory
  # exhaustion: oomd kills the worst-offending cgroup when swap runs low instead
  # of letting the kernel pick a victim (which has historically hit Plex and the
  # Paperless-AI celery worker). Root/system slice enablement applies the
  # swap-based policy (ManagedOOMSwap=kill) to all services.
  systemd.oomd = {
    enable = true;
    enableRootSlice = true;
    enableSystemSlice = true;
    extraConfig = {
      # Kill the highest-swap-usage cgroup once zram swap is 90% full
      # (explicit rather than relying on the compiled-in default)
      SwapUsedLimit = "90%";
    };
  };

  # Daily GC instead of weekly — forge auto-upgrade creates generations almost daily,
  # and the large closure (~53G before cleanup) fills rpool quickly at weekly cadence
  nix.gc.dates = lib.mkForce "daily";
}
