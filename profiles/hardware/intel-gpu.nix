# NOTE: This module should be imported at the host level (not globally)
# to avoid unnecessary option evaluation on hosts that do not require Intel DRI.
{ lib, pkgs, config, ... }:

let
  # Safely resolve the configuration sub-attribute. Some host configs may set
  # `modules.common.intelDri` while others might set `common.intelDri`.
  # Guarded attribute access prevents evaluation errors when intermediate
  # attributes are not present during option parsing.
  cfg =
    if config ? modules && config.modules ? common && config.modules.common ? intelDri then
      config.modules.common.intelDri
    else if config ? common && config.common ? intelDri then
      config.common.intelDri
    else
      { enable = false; driver = "iHD"; services = []; };

in
{
  options.modules.common.intelDri = {
    enable = lib.mkEnableOption "Enable Intel DRI / VA-API support (install drivers & expose render node)";

    # Which userspace VA-API driver to prefer. Use iHD for modern Intel (Gen8+), i965 for legacy.
    driver = lib.mkOption {
      type = lib.types.enum [ "iHD" "i965" ];
      default = "iHD";
      description = "Which VA-API userspace driver to install (intel-media-driver = iHD, legacy = i965).";
    };

  # Optional list of systemd unit names to automatically grant DeviceAllow to.
  # Example: [ "podman-dispatcharr.service" ]
    services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "List of systemd unit names to which the module will add a DeviceAllow for /dev/dri/renderD128 (opt-in).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure i915 kernel module is loaded
    boot.kernelModules = lib.mkDefault [ "i915" ];


    # Install VA-API userland packages so tools like vainfo/ffmpeg can use the HW codecs
    environment.systemPackages = with pkgs;
      (lib.optionals (cfg.driver == "iHD") [ libva libva-utils intel-media-driver intel-gpu-tools ]) ++
      (lib.optionals (cfg.driver == "i965") [ libva libva-utils i965-va-driver intel-gpu-tools ]);

    # Short usage examples available to local admins via /etc
    environment.etc."intel-dri.README".text = ''
This host was provisioned with the Intel DRI support module.

What this module does (when enabled):
- Loads the i915 kernel module so DRM devices appear under /dev/dri
- Installs libva + the selected driver (iHD or i965) and libva-utils (vainfo)

How to grant a service access (recommended):
 - For native systemd services, add a DeviceAllow line and prefer the render node only:
   systemd.services.<name>.serviceConfig.DeviceAllow = [ "/dev/dri/renderD128 rwm" ];
  # Prefer DeviceAllow. Adding `Group = "video"` is usually unnecessary when
  # DeviceAllow is used because DeviceAllow grants the service cgroup direct
  # access to the device node. Only add `Group = "video"` if the service
  # (or a container's internal user mapping) explicitly requires group membership.

 - For containers (podman/docker), bind the render node into the container and avoid --privileged:
     podman run --device /dev/dri:/dev/dri:rw ...

Validation commands:
 - ls -l /dev/dri
 - vainfo
 - sudo intel_gpu_top
 - ffmpeg -hwaccel vaapi -i input.mp4 -f null -
  Notes: `vainfo` is provided by `libva-utils`. `intel_gpu_top` is provided by `intel-gpu-tools`.
'';

    # If the user supplied services to auto-allow, construct systemd.services entries
    # that add a DeviceAllow for the render node. This is intentionally opt-in.
    # We build an attrset mapping unit name -> { serviceConfig = { DeviceAllow = [...] } }
    systemd.services = (if cfg.services == [] then {}
      else builtins.listToAttrs (builtins.map (s: { name = s; value = { serviceConfig = { DeviceAllow = [ "/dev/dri/renderD128 rwm" ]; }; }; }) cfg.services));
  };
}
