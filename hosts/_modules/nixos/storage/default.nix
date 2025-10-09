# /hosts/_modules/nixos/storage/default.nix
{
  config,
  lib,
  ...
}:
with lib;
{
  imports = [
    ./datasets.nix
    ./nfs-mounts.nix
    ./sanoid.nix
    # helpers.nix removed - now using pure helpers-lib.nix imported directly in modules
  ];

  config = let
    notificationsCfg = config.modules.notifications;
    hasCentralizedNotifications = notificationsCfg.enable or false;
  in mkIf hasCentralizedNotifications {

    # Register storage-related notification templates
    modules.notifications.templates = {
      preseed-success = {
        enable = mkDefault true;
        priority = mkDefault "low";
        backend = mkDefault "pushover";
        title = mkDefault ''<b><font color="green">✓ Preseed Success: ''${serviceName}</font></b>'';
        body = mkDefault ''
          <b>Host:</b> ''${hostname}
          <b>Service:</b> <code>''${serviceName}</code>

          Service data was successfully restored before startup.

          <b>Details:</b>
          ''${message}
        '';
      };

      preseed-failure = {
        enable = mkDefault true;
        priority = mkDefault "high";
        backend = mkDefault "pushover";
        title = mkDefault ''<b><font color="red">✗ Preseed Failed: ''${serviceName}</font></b>'';
        body = mkDefault ''
          <b>Host:</b> ''${hostname}
          <b>Service:</b> <code>''${serviceName}</code>

          All automatic restore attempts (ZFS, Restic) failed. The service will start with an empty data directory. Manual intervention may be required.

          <b>Details:</b>
          ''${message}
        '';
      };

      preseed-skipped = {
        enable = mkDefault true;
        priority = mkDefault "low";
        backend = mkDefault "pushover";
        title = mkDefault ''<b><font color="blue">ℹ Preseed Skipped: ''${serviceName}</font></b>'';
        body = mkDefault ''
          <b>Host:</b> ''${hostname}
          <b>Service:</b> <code>''${serviceName}</code>

          Automatic restore was skipped because data was already present.

          <b>Details:</b>
          ''${message}
        '';
      };
    };
  };
}
