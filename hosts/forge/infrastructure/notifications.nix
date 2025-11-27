{ config, ... }:

{
  # Notification system configuration for forge
  # Distributed notification system with Pushover backend
  # Templates auto-register from service modules (backup.nix, zfs-replication.nix, etc.)

  modules = {
    # Distributed notification system
    notifications = {
      enable = true;
      defaultBackend = "pushover";

      pushover = {
        enable = true;
        tokenFile = config.sops.secrets."pushover/token".path;
        userKeyFile = config.sops.secrets."pushover/user-key".path;
        defaultPriority = 0; # Normal priority
        enableHtml = true;
      };
    };

    # System-level notifications (boot/shutdown)
    systemNotifications = {
      enable = true;
      boot.enable = true;
      shutdown.enable = true;
    };
  };
}
