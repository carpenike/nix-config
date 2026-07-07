{ lib
, config
, pkgs
, ...
}:
let
  cfg = config.modules.filesystems.zfs;

  # ZED → homelab notification bridge (see modules/nixos/notifications).
  # Only active when the host has the centralized notification system enabled.
  notificationsEnabled = config.modules.notifications.enable or false;
  zedNotifyEnabled = cfg.zed.pushNotifications && notificationsEnabled;

  # Zedlet dispatching actionable ZFS events to the notify@ infrastructure.
  # ZED invokes zedlets named "<subclass>-*.sh" with event details in ZEVENT_*
  # environment variables; the same script is linked for every subclass we care
  # about. Notifications go through the generic notify@ dispatcher, which reads
  # NOTIFY_* vars from /run/notify/env and renders the "zfs-event" template.
  zedNotifyZedlet = pkgs.writeShellScript "zed-notify-homelab" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.systemd config.boot.zfs.package ]}

    pool="''${ZEVENT_POOL:-unknown}"
    subclass="''${ZEVENT_SUBCLASS:-unknown}"

    case "$subclass" in
      statechange)
        # Only alert on transitions into a bad state (not ONLINE/healthy changes)
        case "''${ZEVENT_VDEV_STATE_STR:-}" in
          FAULTED | DEGRADED | REMOVED | UNAVAIL) ;;
          *) exit 0 ;;
        esac
        details="vdev ''${ZEVENT_VDEV_PATH:-?} changed state to ''${ZEVENT_VDEV_STATE_STR}"
        ;;
      scrub_finish)
        # Only alert when the scrub surfaced problems; stay silent on clean scrubs
        status="$(zpool status "$pool" 2>/dev/null)"
        if echo "$status" | grep -qE 'DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED' \
          || ! echo "$status" | grep -q 'errors: No known data errors'; then
          details="scrub finished WITH ERRORS — check 'zpool status $pool'"
        else
          exit 0
        fi
        ;;
      data | checksum | io)
        # Error-counter events can arrive in bursts (one per failed I/O);
        # rate-limit to one notification per pool+class per hour.
        mkdir -p /run/zed-notify
        stamp="/run/zed-notify/$pool-$subclass"
        now=$(date +%s)
        if [ -e "$stamp" ] && [ $((now - $(stat -c %Y "$stamp"))) -lt 3600 ]; then
          exit 0
        fi
        touch "$stamp"
        details="$subclass error on vdev ''${ZEVENT_VDEV_PATH:-?} (zio_err=''${ZEVENT_ZIO_ERR:-?})"
        ;;
      *)
        exit 0
        ;;
    esac

    # Hand off to the notify@ dispatcher (fixed instance; payload pickup is
    # handled by the notify-pushover@zfs-event:zed path unit)
    mkdir -p /run/notify/env
    env_file="/run/notify/env/zfs-event:zed.env"
    {
      echo "NOTIFY_POOL=$pool"
      echo "NOTIFY_EVENT=$subclass"
      echo "NOTIFY_DETAILS=$details"
    } >"$env_file"
    chgrp notify-ipc "$env_file" 2>/dev/null || true
    chmod 640 "$env_file"

    systemctl start --no-block "notify@zfs-event:zed.service"
    exit 0
  '';
in
{
  options.modules.filesystems.zfs = {
    enable = lib.mkEnableOption "zfs";
    zed.pushNotifications = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Dispatch actionable ZED events (pool/vdev faults, checksum/io/data
        errors, scrubs that finish with errors) through the centralized
        notification system. Only takes effect when modules.notifications
        is enabled on the host; otherwise ZED still runs and logs events
        to syslog via the default all-syslog zedlet.
      '';
    };
    mountPoolsAtBoot = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of ZFS pools to mount at boot";
    };
    persistDataset = lib.mkOption {
      type = lib.types.str;
      default = "rpool/safe/persist";
      description = "ZFS dataset to mount at /persist";
    };
    homeDataset = lib.mkOption {
      type = lib.types.str;
      default = "rpool/safe/home";
      description = "ZFS dataset to mount at /home";
    };
  };

  config = lib.mkIf cfg.enable {
    boot = {
      supportedFilesystems = [ "zfs" ];
      zfs = {
        # RISK: zfs_unstable tracks OpenZFS release candidates/newer releases.
        # Pool features created under it may not import under the stable zfs
        # package, so do NOT downgrade this casually. Combined with unattended
        # auto-upgrades + allowReboot, a kernel/ZFS module mismatch after a
        # nightly upgrade would surface with nobody at the console — recovery
        # relies on systemd-boot generation rollback (boot a previous
        # generation whose kernel+zfs pair is known-good). Keep
        # boot.loader.systemd-boot.configurationLimit high enough to retain
        # known-good generations.
        package = pkgs.zfs_unstable;
        # forceImportRoot helps when the root filesystem is on ZFS
        # Set to true since we're using ZFS for root
        forceImportRoot = true;
        requestEncryptionCredentials = true;
        extraPools = cfg.mountPoolsAtBoot;
      };
    };

    # Use standard fileSystems configuration for ZFS mounts
    # These are typically defined by disko-config.nix, but we provide defaults
    # Note: disko-config definitions take precedence over these
    # IMPORTANT: Use "zfsutil" option for legacy mountpoints to avoid race conditions
    fileSystems."/persist" = lib.mkDefault {
      device = cfg.persistDataset;
      fsType = "zfs";
      options = [ "zfsutil" "X-mount.mkdir" ];
      neededForBoot = true;
    };

    fileSystems."/home" = lib.mkDefault {
      device = cfg.homeDataset;
      fsType = "zfs";
      options = [ "zfsutil" "X-mount.mkdir" ];
      neededForBoot = true;
    };

    # ZFS services configuration
    services.zfs = {
      autoScrub.enable = true;
      trim.enable = true;

      # ZED (ZFS Event Daemon) — re-enabled so pool/vdev faults, I/O errors and
      # scrub results are observable. The default all-syslog zedlet keeps every
      # event in the journal; push notifications are wired below when the
      # centralized notification system is available.
      zed = {
        # No sendmail on these hosts; notifications go through notify@ instead
        enableMail = false;
        settings = {
          # Built-in *-notify zedlets: only notify on problems, not clean scrubs
          ZED_NOTIFY_VERBOSE = false;
          ZED_NOTIFY_INTERVAL_SECS = 3600;
        };
      };
    };

    # =========================================================================
    # Push notifications for actionable ZFS events
    # (via modules/nixos/notifications; only when that module is enabled)
    # =========================================================================

    # Install the dispatch zedlet for each event subclass we alert on.
    # ZED runs every executable in /etc/zfs/zed.d whose name starts with the
    # event subclass (or "all-"). These sit alongside the default zedlets
    # (all-syslog.sh etc.) that the NixOS module installs from the ZFS package.
    environment.etc = lib.mkIf zedNotifyEnabled (lib.genAttrs
      (map (subclass: "zfs/zed.d/${subclass}-notify-homelab.sh") [
        "statechange" # vdev/pool state transitions (FAULTED/DEGRADED/...)
        "scrub_finish" # scrubs that completed WITH errors
        "data" # data corruption errors
        "checksum" # checksum errors
        "io" # I/O errors
      ])
      (_: { source = zedNotifyZedlet; }));

    # Notification template rendered by the notify@ dispatcher
    modules.notifications.templates = lib.mkIf zedNotifyEnabled {
      zfs-event = {
        enable = lib.mkDefault true;
        priority = lib.mkDefault "high";
        title = "⚠️ ZFS Event: \${pool}";
        body = ''
          <b>Host:</b> ''${hostname}
          <b>Pool:</b> ''${pool}
          <b>Event:</b> ''${event}

          ''${details}

          Check with: zpool status ''${pool}
        '';
      };
    };

    # Path unit instance that triggers the Pushover backend when the
    # dispatcher drops the payload (same pattern as system-notifications.nix)
    systemd.paths."notify-pushover@zfs-event:zed" = lib.mkIf zedNotifyEnabled {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = "/run/notify/zfs-event:zed.json";
      };
    };
  };
}
