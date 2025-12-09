{ config, lib, pkgs, ... }:
let
  cfg = config.modules.hardware.raspberryPi;
in
{
  options.modules.hardware.raspberryPi = {
    enable = lib.mkEnableOption "Raspberry Pi 4 hardware support";
  };

  config = lib.mkIf cfg.enable {
    # Boot configuration for Raspberry Pi 4
    boot = {
      loader = {
        # Use generic extlinux-compatible bootloader (recommended for Pi 4)
        # Using mkDefault to allow raspberry-pi-nix to override if needed
        generic-extlinux-compatible = {
          enable = lib.mkDefault true;
          configurationLimit = lib.mkDefault 1;
        };
        grub.enable = lib.mkDefault false;
      };

      # Use the Raspberry Pi-specific kernel
      kernelPackages = lib.mkDefault pkgs.linuxPackages_rpi4;

      # Enable GPIO and other Pi-specific kernel modules
      kernelModules = [ "i2c-dev" ];

      # Kernel parameters for better Pi 4 performance
      kernelParams = [
        "cma=256M"
        "console=ttyS0,115200n8"
        "console=tty0"
        "console=ttyGS0,115200" # USB gadget serial console
      ];
    };

    # Hardware-specific packages
    environment.systemPackages = with pkgs; [
      libraspberrypi
      raspberrypi-eeprom
    ];

    # Enable hardware watchdog
    systemd.services.watchdog = {
      description = "Hardware watchdog";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.busybox}/bin/watchdog -T 10 -t 5 /dev/watchdog";
        Restart = "always";
      };
    };

    # GPIO access permissions
    services.udev.extraRules = ''
      SUBSYSTEM=="gpio", GROUP="gpio", MODE="0660"
      SUBSYSTEM=="i2c-dev", GROUP="i2c", MODE="0660"
    '';

    # Create groups for hardware access
    users.groups = {
      gpio = { };
      i2c = { };
    };
  };
}
