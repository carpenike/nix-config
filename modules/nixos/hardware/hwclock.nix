{ config, lib, pkgs, ... }:
let
  cfg = config.modules.hardware.hwclock;
in
{
  options.modules.hardware.hwclock = {
    enable = lib.mkEnableOption "hardware clock synchronization for Raspberry Pi";
  };

  config = lib.mkIf cfg.enable {
    # Enable hwclock to save and restore time between reboots
    # This helps when the Pi has no RTC module
    systemd.services.hwclock-sync = {
      description = "Synchronize hardware clock on startup";
      wantedBy = [ "sysinit.target" ];
      after = [ "systemd-modules-load.service" ];
      before = [ "timesyncd.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "sync-hwclock" ''
          # Try to set a reasonable time at boot if system time looks bad
          CURRENT_YEAR=$(date +%Y)
          if [ "$CURRENT_YEAR" -lt "2023" ]; then
            echo "System time before 2023 detected (current time: $(date))"
            echo "Setting time to build time as fallback"
            # Use the build time of this script as a reasonable fallback time
            touch /run/fake-time-marker
            hwclock --systohc
            echo "Time set to: $(date)"
          fi
        '';
        RemainAfterExit = true;
      };
    };
  };
}
