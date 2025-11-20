{ lib, config, ... }:

let
  cfg = config.modules.hardware.coralTpu or {
    enable = false;
    usb.enable = true;
    pcie.enable = false;
    systemUsers = [];
  };
  coralGroup = "coral";
in
{
  options.modules.hardware.coralTpu = {
    enable = lib.mkEnableOption "opinionated Coral Edge TPU wiring (wraps hardware.coral)";

    usb.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Expose USB Coral accelerators via hardware.coral";
    };

    pcie.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Expose PCIe/M.2 Coral accelerators (loads gasket driver).";
    };

    systemUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "System users that require read/write access to Coral devices (e.g., frigate).";
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.coral.usb.enable = cfg.usb.enable;
    hardware.coral.pcie.enable = cfg.pcie.enable;

    users.users = lib.mkMerge (map (user: {
      ${user} = {
        extraGroups = lib.mkAfter [ coralGroup ];
      };
    }) cfg.systemUsers);
  };
}
