{ lib, ... }:

{
  # Boot loader configuration
  boot.loader = {
    systemd-boot.enable = true;
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

  # Daily GC instead of weekly — forge auto-upgrade creates generations almost daily,
  # and the large closure (~53G before cleanup) fills rpool quickly at weekly cadence
  nix.gc.dates = lib.mkForce "daily";
}
