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
      { enable = false; driver = "iHD"; renderNode = "/dev/dri/renderD128"; services = [ ]; };

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

    # Which render node to hand out via DeviceAllow. NOT always renderD128: on
    # multi-GPU hosts the numbering depends on probe order, so the Intel node may
    # be renderD129 or higher (check /dev/dri/by-path or /sys/class/drm/*/device/uevent).
    renderNode = lib.mkOption {
      type = lib.types.str;
      default = "/dev/dri/renderD128";
      example = "/dev/dri/renderD129";
      description = "Path to the Intel render node granted by the `services` DeviceAllow entries.";
    };

    # Optional list of systemd unit names to automatically grant DeviceAllow to.
    # Either spelling works: "foo" and "foo.service" both target foo.service.
    #
    # NOTE: this is only useful for *native* systemd services. Podman/Docker
    # containers run in their own cgroup under machine.slice, not under the
    # unit's cgroup, so a unit-level DeviceAllow does not reach the container --
    # pass the device into the container instead (--device=/dev/dri:/dev/dri:rwm).
    # Example: [ "jellyfin" ]
    services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "jellyfin" ];
      description = ''
        List of systemd unit names to which the module will add a DeviceAllow for
        `renderNode` (opt-in). A trailing ".service" is stripped, so both "foo" and
        "foo.service" refer to foo.service.

        Only affects native systemd services; container runtimes need the device
        passed in at the container level instead.
      '';
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
         systemd.services.<name>.serviceConfig.DeviceAllow = [ "${cfg.renderNode} rwm" ];
        # Prefer DeviceAllow. Adding `Group = "video"` is usually unnecessary when
        # DeviceAllow is used because DeviceAllow grants the service cgroup direct
        # access to the device node. Only add `Group = "video"` if the service
        # (or a container's internal user mapping) explicitly requires group membership.
        # Note that DeviceAllow is a whitelist: once any entry is present, every other
        # device node is denied to that unit.

       - For containers (podman/docker), bind the render node into the container and avoid --privileged:
           podman run --device /dev/dri:/dev/dri:rw ...
        # DeviceAllow on the *unit* does nothing for these: the container payload lives in
        # its own cgroup under machine.slice, outside the unit's cgroup, so the unit's
        # device filter never applies to it.

      Identifying the Intel render node (numbering is probe-order dependent, so
      renderD128 may well belong to a discrete GPU):
       - ls -l /dev/dri/by-path
       - grep -H DRIVER /sys/class/drm/render*/device/uevent

      Validation commands (pass the device explicitly; vainfo's default is renderD128,
      which is not necessarily the Intel node):
       - ls -l /dev/dri
       - vainfo --display drm --device ${cfg.renderNode}
       - sudo intel_gpu_top
       - ffmpeg -hwaccel vaapi -vaapi_device ${cfg.renderNode} -i input.mp4 -f null -
        Notes: `vainfo` is provided by `libva-utils`. `intel_gpu_top` is provided by `intel-gpu-tools`.
    '';

    # If the user supplied services to auto-allow, construct systemd.services entries
    # that add a DeviceAllow for the render node. This is intentionally opt-in.
    # We build an attrset mapping unit name -> { serviceConfig = { DeviceAllow = [...] } }
    #
    # NixOS appends ".service" to each `systemd.services.<name>` key, so a key
    # that already carries the suffix renders as `<name>.service.service` — a
    # phantom unit that is never loaded, silently discarding the DeviceAllow.
    # Callers historically wrote the suffix (the option's example above shows
    # it), so strip a trailing ".service" and accept both spellings.
    systemd.services = builtins.listToAttrs (builtins.map
      (s: {
        name = lib.removeSuffix ".service" s;
        value = { serviceConfig = { DeviceAllow = [ "${cfg.renderNode} rwm" ]; }; };
      })
      cfg.services);
  };
}
