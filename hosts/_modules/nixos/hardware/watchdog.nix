{ config, lib, pkgs, ... }:
let
  cfg = config.modules.hardware.watchdog;
in
{
  options.modules.hardware.watchdog = {
    enable = lib.mkEnableOption "hardware watchdog timer for Raspberry Pi";
  };

  config = lib.mkIf cfg.enable {
    # Enable the hardware watchdog timer
    boot.kernelModules = [ "bcm2835_wdt" ];

    # Configure systemd to use the watchdog
    systemd.extraConfig = ''
      RuntimeWatchdogSec=30s
      ShutdownWatchdogSec=10s
    '';
  };
}
