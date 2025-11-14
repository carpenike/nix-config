{ pkgs, ... }:

{
  # Expose VA-API drivers for host-side tools (vainfo, ffmpeg)
  # hardware.opengl was renamed; migrate to hardware.graphics
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [ intel-media-driver libva libva-utils ];
  };

  # Enable Intel DRI / VA-API support on this host
  # This exposes /dev/dri/* devices to containers that need GPU access
  # Individual service modules configure their own container device mappings
}
