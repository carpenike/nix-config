{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.modules.services.coachiq;
in
{
  options.modules.services.coachiq = {
    enable = lib.mkEnableOption "CoachIQ RV monitoring service";

    user = lib.mkOption {
      type = lib.types.str;
      default = "coachiq";
      description = "User to run the service as";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "coachiq";
      description = "Group to run the service as";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create user and group for coachiq
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      extraGroups = [ "dialout" ]; # For CAN bus access
    };

    users.groups.${cfg.group} = {};

    # Note: The actual coachiq service configuration will be handled
    # by importing the coachiq NixOS module at the host level
  };
}
