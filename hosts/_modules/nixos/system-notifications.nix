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
        title = mkDefault ''<b><font color="green">🚀 System Boot</font></b>'';
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
        title = mkDefault ''<b><font color="orange">⏸️ System Shutdown</font></b>'';
        body = mkDefault ''
<b>Host:</b> ''${hostname}
<b>Time:</b> ''${shutdowntime}

<b>Uptime:</b> ''${uptime}

System is shutting down gracefully.
        '';
      };
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
        export NOTIFY_HOSTNAME="${config.networking.hostName}"
        export NOTIFY_BOOTTIME="$(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')"
        export NOTIFY_KERNEL="$(${pkgs.coreutils}/bin/uname -r)"
        export NOTIFY_GENERATION="$(${pkgs.coreutils}/bin/basename $(${pkgs.coreutils}/bin/readlink /run/current-system) | ${pkgs.gnused}/bin/sed 's/.*-//')"
        export NOTIFY_UPTIME="$(${pkgs.procps}/bin/uptime | ${pkgs.gnused}/bin/sed -E 's/.*up (.*), *[0-9]+ users?.*/\1/')"

        # Wait a bit for network to be fully ready
        sleep 5

        # Trigger notification through generic dispatcher
        ${pkgs.systemd}/bin/systemctl start "notify@system-boot:boot.service"
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
        export NOTIFY_HOSTNAME="${config.networking.hostName}"
        export NOTIFY_SHUTDOWNTIME="$(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')"
        export NOTIFY_UPTIME="$(${pkgs.procps}/bin/uptime | ${pkgs.gnused}/bin/sed -E 's/.*up (.*), *[0-9]+ users?.*/\1/')"

        # Trigger notification through generic dispatcher
        # Note: Must complete quickly before network shuts down
        ${pkgs.systemd}/bin/systemctl start "notify@system-shutdown:shutdown.service" || true
      '';
    };
  };
}
