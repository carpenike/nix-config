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
        priority = mkDefault "low";  # Low priority to reduce noise
        backend = mkDefault "pushover";
        title = mkDefault ''🚀 System Boot'';
        body = mkDefault ''
<b>Host:</b> ''${hostname}
<b>Time:</b> ''${boottime}

<b>System Info:</b>
• Kernel: ''${kernel}
• NixOS Generation: ''${generation}

System is online and ready.
        '';
      };      system-shutdown = {
        enable = mkDefault cfg.shutdown.enable;
        priority = mkDefault "low";
        backend = mkDefault "pushover";
        title = mkDefault ''⏸️ System Shutdown'';
        body = mkDefault ''
<b>Host:</b> ''${hostname}
<b>Time:</b> ''${shutdowntime}

<b>Uptime:</b> ''${uptime}

System is shutting down gracefully.
        '';
      };
    };

    # Enable path unit for boot notifications
    # Watches for payload file and triggers the backend service
    # Must explicitly define PathExists since we're creating an instance, not using the template
    systemd.paths."notify-pushover@system-boot:boot" = mkIf cfg.boot.enable {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = "/run/notify/system-boot:boot.json";
      };
    };

    # Note: No path unit for shutdown - it sends notifications directly in ExecStop
    # to avoid systemd's restrictions on starting new services during shutdown

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
        # Gather system information
        NOTIFY_HOSTNAME="${config.networking.hostName}"
        NOTIFY_BOOTTIME="$(${pkgs.coreutils}/bin/date '+%b %-d, %-I:%M %p %Z')"
        NOTIFY_KERNEL="$(${pkgs.coreutils}/bin/uname -r)"
        NOTIFY_GENERATION="$(${pkgs.coreutils}/bin/basename $(${pkgs.coreutils}/bin/readlink /run/current-system) | ${pkgs.gnused}/bin/sed 's/.*-//')"

        # Wait a bit for network to be fully ready
        sleep 5

        # Write environment variables to a file for the dispatcher
        # Directory is created by tmpfiles (boot) and activationScripts (nixos-rebuild)
        ENV_FILE="/run/notify/env/system-boot:boot.env"
        {
          echo "NOTIFY_HOSTNAME=$NOTIFY_HOSTNAME"
          echo "NOTIFY_BOOTTIME=$NOTIFY_BOOTTIME"
          echo "NOTIFY_KERNEL=$NOTIFY_KERNEL"
          echo "NOTIFY_GENERATION=$NOTIFY_GENERATION"
        } > "$ENV_FILE"
        chgrp notify-ipc "$ENV_FILE"
        chmod 640 "$ENV_FILE"

        # Trigger notification through generic dispatcher
        ${pkgs.systemd}/bin/systemctl start "notify@system-boot:boot.service"
      '';
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
        ExecStop = let
          pushoverCfg = config.modules.notifications.pushover;
        in pkgs.writeShellScript "notify-shutdown" ''
          set -euo pipefail

          # Debug: Log to both stderr and a persistent file
          LOGFILE="/persist/var/log/shutdown-notify-debug.log"
          echo "[SHUTDOWN-NOTIFY] ExecStop started at $(${pkgs.coreutils}/bin/date)" >&2
          echo "[SHUTDOWN-NOTIFY] ExecStop started at $(${pkgs.coreutils}/bin/date)" >> "$LOGFILE"

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
          echo "[SHUTDOWN-NOTIFY] Reading credentials..." >&2
          echo "[SHUTDOWN-NOTIFY] Reading credentials..." >> "$LOGFILE"
          PUSHOVER_TOKEN=$(${pkgs.coreutils}/bin/cat ${pushoverCfg.tokenFile})
          PUSHOVER_USER=$(${pkgs.coreutils}/bin/cat ${pushoverCfg.userKeyFile})

          echo "[SHUTDOWN-NOTIFY] Sending notification to Pushover..." >&2
          echo "[SHUTDOWN-NOTIFY] Sending notification to Pushover..." >> "$LOGFILE"

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

          echo "[SHUTDOWN-NOTIFY] HTTP response: $HTTP_CODE" >&2
          echo "[SHUTDOWN-NOTIFY] HTTP response: $HTTP_CODE" >> "$LOGFILE"

          # Return success even if notification fails (don't block shutdown)
          exit 0
        '';
      };
    };
  };
}
