{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.modules.systemNotifications;
  notificationsCfg = config.modules.notifications;
  hasCentralizedNotifications = notificationsCfg.enable or false;
in
{
  options.modules.systemNotifications = {
    enable = mkEnableOption "System-wide notification events (boot, shutdown)";

    boot = {
      enable = mkEnableOption "Boot notification" // { default = true; };
    };

    shutdown = {
      enable = mkEnableOption "Shutdown notification" // { default = true; };
    };
  };

  config = mkIf (cfg.enable && hasCentralizedNotifications) {
    # Register notification templates
    modules.notifications.templates = {
      system-boot = {
        enable = mkDefault cfg.boot.enable;
        priority = mkDefault "low"; # Low priority to reduce noise
        backend = mkDefault "pushover";
        placeholders = [ "boottime" "bootstatus" "kernel" "generation" ];
        title = mkDefault ''🚀 System Boot'';
        body = mkDefault ''
          <b>Host:</b> ''${hostname}
          <b>Time:</b> ''${boottime}

          <b>Boot Status:</b> ''${bootstatus}

          <b>System Info:</b>
          • Kernel: ''${kernel}
          • NixOS Generation: ''${generation}

          System is online and ready.
        '';
      };
      system-shutdown = {
        enable = mkDefault cfg.shutdown.enable;
        priority = mkDefault "low";
        backend = mkDefault "pushover";
        # Registered for documentation only: the shutdown path cannot start a
        # service, so notify-shutdown.service below renders this content itself.
        placeholders = [ "shutdowntime" "uptime" ];
        title = mkDefault ''⏸️ System Shutdown'';
        body = mkDefault ''
          <b>Host:</b> ''${hostname}
          <b>Time:</b> ''${shutdowntime}

          <b>Uptime:</b> ''${uptime}

          System is shutting down gracefully.
        '';
      };
    };

    # No path unit here any more: notify-drain.path watches /run/notify as a
    # directory, so every payload is picked up rather than only the handful
    # that happened to have an instance declared.
    #
    # Note: shutdown still sends its notification directly in ExecStop, to
    # avoid systemd's restrictions on starting new services during shutdown.

    # Boot notification service
    systemd.services.notify-boot = mkIf cfg.boot.enable {
      description = "Send system boot notification";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
      wants = [ "network-online.target" "systemd-tmpfiles-setup.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Directory is created by tmpfiles rules with proper permissions
      };

      script = ''
        # Check for graceful shutdown marker
        MARKER_FILE="/persist/var/lib/shutdown-marker/clean"
        if [ -f "$MARKER_FILE" ]; then
          BOOT_STATUS="✅ Clean boot (graceful shutdown)"
          # Clean up the marker so next boot is considered unclean by default
          rm "$MARKER_FILE"
        else
          # Check if ZFS had to recover (additional confirmation of dirty boot)
          if ${pkgs.systemd}/bin/journalctl -b 0 --no-pager | ${pkgs.gnugrep}/bin/grep -qi "zfs.*import"; then
            BOOT_STATUS="⚠️ Unclean boot (crash/power loss - ZFS recovery)"
          else
            BOOT_STATUS="⚠️ Unclean boot (crash/power loss)"
          fi
        fi

        # Gather system information
        BOOT_TIME="$(${pkgs.coreutils}/bin/date '+%b %-d, %-I:%M %p %Z')"
        KERNEL="$(${pkgs.coreutils}/bin/uname -r)"
        GENERATION="$(${pkgs.coreutils}/bin/basename $(${pkgs.coreutils}/bin/readlink /run/current-system) | ${pkgs.gnused}/bin/sed 's/.*-//')"

        # Wait a bit for network to be fully ready
        sleep 5

        # Hand the dispatcher this boot's placeholder values as JSON.
        #
        # This used to be an EnvironmentFile, which cannot carry the multi-line
        # values other callers need and silently mangles anything with quoting
        # in it. JSON has one unambiguous representation, and the keys are the
        # placeholder names verbatim rather than being run through a lossy
        # NOTIFY_BOOT_TIME -> boottime transform.
        CTX_FILE="/run/notify/ctx/system-boot:boot.json"
        ${pkgs.jq}/bin/jq -n \
          --arg boottime "$BOOT_TIME" \
          --arg bootstatus "$BOOT_STATUS" \
          --arg kernel "$KERNEL" \
          --arg generation "$GENERATION" \
          '{boottime: $boottime, bootstatus: $bootstatus, kernel: $kernel, generation: $generation}' \
          > "$CTX_FILE"
        chgrp notify-ipc "$CTX_FILE"
        chmod 660 "$CTX_FILE"

        # Trigger notification through generic dispatcher
        ${pkgs.systemd}/bin/systemctl start "notify@system-boot:boot.service"
      '';
    };

    # Graceful shutdown marker service
    # Creates a flag file during shutdown to indicate graceful shutdown
    # Uses ExecStop pattern: service is active during runtime, creates marker when stopped
    systemd.services.graceful-shutdown-marker = mkIf cfg.shutdown.enable {
      description = "Create marker for graceful shutdown";
      wantedBy = [ "multi-user.target" ];
      before = [ "umount.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/true";
        ExecStop = pkgs.writeShellScript "create-shutdown-marker" ''
          ${pkgs.coreutils}/bin/mkdir -p /persist/var/lib/shutdown-marker
          ${pkgs.coreutils}/bin/touch /persist/var/lib/shutdown-marker/clean
        '';
      };
    };

    # Shutdown notification service
    systemd.services.notify-shutdown = mkIf cfg.shutdown.enable {
      description = "Send system shutdown notification";

      wantedBy = [ "multi-user.target" ];
      # Key ordering: after network-online.target ensures we start AFTER network is up,
      # and systemd reverses this during shutdown, stopping us BEFORE network goes down
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Run before final shutdown stages
      before = [ "shutdown.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Keep default dependencies but ensure we run early in shutdown
        DefaultDependencies = true;
        # Ensure the ExecStop script isn't killed before completion
        KillMode = "none";
        # Give it plenty of time to send the notification
        TimeoutStopSec = "30s";

        # At boot: do nothing, just enter active (exited) state
        ExecStart = "${pkgs.coreutils}/bin/true";

        # At shutdown: send notification directly while network is still up
        # Cannot use systemctl start during shutdown, must be self-contained
        ExecStop =
          let
            pushoverCfg = config.modules.notifications.pushover;
          in
          pkgs.writeShellScript "notify-shutdown" ''
                      set -euo pipefail

                      # Gather system information
                      HOSTNAME="${config.networking.hostName}"
                      SHUTDOWNTIME="$(${pkgs.coreutils}/bin/date '+%b %-d, %-I:%M %p %Z')"
                      UPTIME="$(${pkgs.procps}/bin/uptime | ${pkgs.gnused}/bin/sed -E 's/.*up (.*), *[0-9]+ users?.*/\1/')"

                      # Build notification message (hardcoded for reliability during shutdown)
                      # Note: Bypasses template system since we can't load JSON during shutdown
                      TITLE="⏸️ System Shutdown"
                      MESSAGE="<b>Host:</b> $HOSTNAME
            <b>Time:</b> $SHUTDOWNTIME

            <b>Uptime:</b> $UPTIME

            System is shutting down gracefully."

                      # Read Pushover credentials directly from sops secret files
                      # LoadCredential doesn't work during shutdown due to permission issues
                      PUSHOVER_TOKEN=$(${pkgs.coreutils}/bin/cat ${pushoverCfg.tokenFile})
                      PUSHOVER_USER=$(${pkgs.coreutils}/bin/cat ${pushoverCfg.userKeyFile})

                      # Send notification directly (cannot start services during shutdown)
                      HTTP_CODE=$(${pkgs.curl}/bin/curl -s -w "%{http_code}" -o /dev/null \
                        --max-time 10 \
                        --data-urlencode "token=$PUSHOVER_TOKEN" \
                        --data-urlencode "user=$PUSHOVER_USER" \
                        --data-urlencode "title=$TITLE" \
                        --data-urlencode "message=$MESSAGE" \
                        --data-urlencode "priority=-1" \
                        --data-urlencode "html=1" \
                        "https://api.pushover.net/1/messages.json" || echo "000")

                      # Return success even if notification fails (don't block shutdown)
                      exit 0
          '';
      };
    };
  };
}
