{ pkgs, ... }:

{
  # Expose VA-API drivers for host-side tools (vainfo, ffmpeg)
  # hardware.opengl was renamed; migrate to hardware.graphics
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [ intel-media-driver libva libva-utils ];
  };

  # Bluetooth support for Home Assistant BLE device integration
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # BlueZ service for Bluetooth stack
  services.blueman.enable = false; # No GUI needed on server

  # Enable Intel DRI / VA-API support on this host
  # This exposes /dev/dri/* devices to containers that need GPU access
  # Individual service modules configure their own container device mappings
}
