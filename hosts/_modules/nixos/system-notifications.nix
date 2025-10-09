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

    # Enable path units for boot/shutdown notifications
    # These watch for payload files and trigger the backend services
    # Must explicitly define PathExists since we're creating instances, not using the template
    systemd.paths."notify-pushover@system-boot:boot" = mkIf cfg.boot.enable {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = "/run/notify/system-boot:boot.json";
      };
    };

    systemd.paths."notify-pushover@system-shutdown:shutdown" = mkIf cfg.shutdown.enable {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = "/run/notify/system-shutdown:shutdown.json";
      };
    };

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
      # Run before network shuts down during shutdown sequence
      before = [ "network-pre.target" "shutdown.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Remove default dependencies for full control over shutdown ordering
        DefaultDependencies = false;

        # At boot: do nothing, just enter active (exited) state
        ExecStart = "${pkgs.coreutils}/bin/true";

        # At shutdown: send notification while network is still up
        ExecStop = pkgs.writeShellScript "notify-shutdown" ''
          # Gather system information
          NOTIFY_HOSTNAME="${config.networking.hostName}"
          NOTIFY_SHUTDOWNTIME="$(${pkgs.coreutils}/bin/date '+%b %-d, %-I:%M %p %Z')"
          NOTIFY_UPTIME="$(${pkgs.procps}/bin/uptime | ${pkgs.gnused}/bin/sed -E 's/.*up (.*), *[0-9]+ users?.*/\1/')"

          # Write environment variables to a file for the dispatcher
          # Directory is created by tmpfiles (boot) and activationScripts (nixos-rebuild)
          ENV_FILE="/run/notify/env/system-shutdown:shutdown.env"
          {
            echo "NOTIFY_HOSTNAME=$NOTIFY_HOSTNAME"
            echo "NOTIFY_SHUTDOWNTIME=$NOTIFY_SHUTDOWNTIME"
            echo "NOTIFY_UPTIME=$NOTIFY_UPTIME"
          } > "$ENV_FILE"
          chgrp notify-ipc "$ENV_FILE"
          chmod 640 "$ENV_FILE"

          # Trigger notification through generic dispatcher
          # Note: Must complete quickly before network shuts down
          ${pkgs.systemd}/bin/systemctl start "notify@system-shutdown:shutdown.service" || true
        '';
      };
    };
  };
}
