# hosts/nas-0/core/monitoring.nix
#
# Monitoring configuration for nas-0
#
# This file enables node_exporter for Prometheus scraping by forge.
# Alerts for nas-0 are defined on forge (where Prometheus runs) in:
#   hosts/forge/infrastructure/nas-monitoring.nix

{ pkgs, ... }:

{
  # =============================================================================
  # Prometheus Node Exporter
  # =============================================================================

  # Enable node_exporter for system metrics
  # Scraped by Prometheus on forge
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;

    # Enable collectors relevant for NAS workload
    enabledCollectors = [
      "systemd" # Systemd unit states
      "filesystem" # Filesystem usage
      "diskstats" # Disk I/O statistics (critical for 28 drives)
      "netdev" # Network interface stats
      "meminfo" # Memory usage
      "loadavg" # System load
      "cpu" # CPU usage
      "time" # System time
      "textfile" # Custom metrics via textfile
    ];

    # Disable collectors that add noise
    disabledCollectors = [
      "arp"
      "bcache"
      "bonding"
      "btrfs"
      "conntrack"
      "entropy"
      "fibrechannel"
      "hwmon" # Can be noisy with many drives
      "infiniband"
      "ipvs"
      "mdadm"
      "nfs" # We're the NFS server, not client
      "nfsd" # Covered by explicit NFS metrics if needed
      "nvme" # Boot drive only
      "powersupplyclass"
      "pressure"
      "rapl"
      "schedstat"
      "sockstat"
      "softnet"
      "tapestats"
      "thermal_zone"
      "udp_queues"
      "xfs"
    ];
  };

  # =============================================================================
  # ZFS Metrics via Textfile Collector
  # =============================================================================

  # Create directory for textfile collector metrics
  systemd.tmpfiles.rules = [
    "d /var/lib/node_exporter/textfile_collector 0755 root root -"
  ];

  # Timer to collect ZFS metrics
  systemd.services.zfs-metrics-collector = {
    description = "Collect ZFS metrics for Prometheus";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = toString (pkgs.writeShellScript "zfs-metrics" ''
        #!/bin/sh
        OUTPUT="/var/lib/node_exporter/textfile_collector/zfs.prom"
        TEMP="$OUTPUT.tmp"

        # Pool health
        for pool in $(${pkgs.zfs}/bin/zpool list -H -o name); do
          health=$(${pkgs.zfs}/bin/zpool list -H -o health "$pool")
          case "$health" in
            ONLINE) health_val=0 ;;
            DEGRADED) health_val=1 ;;
            FAULTED) health_val=2 ;;
            OFFLINE) health_val=3 ;;
            *) health_val=4 ;;
          esac
          echo "zfs_pool_health{pool=\"$pool\",state=\"$health\"} $health_val" >> "$TEMP"

          # Pool capacity
          size=$(${pkgs.zfs}/bin/zpool list -H -p -o size "$pool")
          alloc=$(${pkgs.zfs}/bin/zpool list -H -p -o alloc "$pool")
          free=$(${pkgs.zfs}/bin/zpool list -H -p -o free "$pool")
          echo "zfs_pool_size_bytes{pool=\"$pool\"} $size" >> "$TEMP"
          echo "zfs_pool_allocated_bytes{pool=\"$pool\"} $alloc" >> "$TEMP"
          echo "zfs_pool_free_bytes{pool=\"$pool\"} $free" >> "$TEMP"
        done

        mv "$TEMP" "$OUTPUT"
      '');
    };
  };

  systemd.timers.zfs-metrics-collector = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
    };
  };

  # =============================================================================
  # Firewall - Allow Prometheus Scraping from Forge
  # =============================================================================

  networking.firewall.allowedTCPPorts = [
    9100 # node_exporter
  ];
}
