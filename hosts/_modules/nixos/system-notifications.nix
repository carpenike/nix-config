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
• Uptime: ''${uptime}

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
    systemd.paths."notify-pushover@system-boot:boot" = mkIf cfg.boot.enable {
      wantedBy = [ "multi-user.target" ];
    };

    systemd.paths."notify-pushover@system-shutdown:shutdown" = mkIf cfg.shutdown.enable {
      wantedBy = [ "multi-user.target" ];
    };

    # Boot notification service
    systemd.services.notify-boot = mkIf cfg.boot.enable {
      description = "Send system boot notification";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Gather system information
        NOTIFY_HOSTNAME="${config.networking.hostName}"
        NOTIFY_BOOTTIME="$(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')"
        NOTIFY_KERNEL="$(${pkgs.coreutils}/bin/uname -r)"
        NOTIFY_GENERATION="$(${pkgs.coreutils}/bin/basename $(${pkgs.coreutils}/bin/readlink /run/current-system) | ${pkgs.gnused}/bin/sed 's/.*-//')"
        NOTIFY_UPTIME="$(${pkgs.procps}/bin/uptime | ${pkgs.gnused}/bin/sed -E 's/.*up (.*), *[0-9]+ users?.*/\1/')"

        # Wait a bit for network to be fully ready
        sleep 5

        # Set environment variables for the dispatcher service
        ${pkgs.systemd}/bin/systemctl set-environment \
          "NOTIFY_HOSTNAME=$NOTIFY_HOSTNAME" \
          "NOTIFY_BOOTTIME=$NOTIFY_BOOTTIME" \
          "NOTIFY_KERNEL=$NOTIFY_KERNEL" \
          "NOTIFY_GENERATION=$NOTIFY_GENERATION" \
          "NOTIFY_UPTIME=$NOTIFY_UPTIME"

        # Trigger notification through generic dispatcher
        ${pkgs.systemd}/bin/systemctl start "notify@system-boot:boot.service"

        # Clean up environment variables
        ${pkgs.systemd}/bin/systemctl unset-environment \
          NOTIFY_HOSTNAME NOTIFY_BOOTTIME NOTIFY_KERNEL NOTIFY_GENERATION NOTIFY_UPTIME
      '';
    };

    # Shutdown notification service
    systemd.services.notify-shutdown = mkIf cfg.shutdown.enable {
      description = "Send system shutdown notification";
      wantedBy = [ "shutdown.target" ];
      before = [ "shutdown.target" ];

      serviceConfig = {
        Type = "oneshot";
        DefaultDependencies = false;
      };

      script = ''
        # Gather system information
        NOTIFY_HOSTNAME="${config.networking.hostName}"
        NOTIFY_SHUTDOWNTIME="$(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')"
        NOTIFY_UPTIME="$(${pkgs.procps}/bin/uptime | ${pkgs.gnused}/bin/sed -E 's/.*up (.*), *[0-9]+ users?.*/\1/')"

        # Set environment variables for the dispatcher service
        ${pkgs.systemd}/bin/systemctl set-environment \
          "NOTIFY_HOSTNAME=$NOTIFY_HOSTNAME" \
          "NOTIFY_SHUTDOWNTIME=$NOTIFY_SHUTDOWNTIME" \
          "NOTIFY_UPTIME=$NOTIFY_UPTIME"

        # Trigger notification through generic dispatcher
        # Note: Must complete quickly before network shuts down
        ${pkgs.systemd}/bin/systemctl start "notify@system-shutdown:shutdown.service" || true

        # Clean up environment variables
        ${pkgs.systemd}/bin/systemctl unset-environment \
          NOTIFY_HOSTNAME NOTIFY_SHUTDOWNTIME NOTIFY_UPTIME || true
      '';
    };
  };
}
