#############################################################
#
#  Rydev - Remote Installation Test Lab
#  NixOS running on Parallels VM
#
###############################################################

{ inputs, configLib, ... }: {
  imports = [
    #################### Required Configs ####################
    ./hardware-configuration.nix
    (configLib.relativeToRoot "hosts/common/core")

    #################### Optional Configs ####################
    (configLib.relativeToRoot "hosts/common/optional/services/openssh.nix")

    #################### Users to Create ####################
    (configLib.relativeToRoot "hosts/common/users/ryan")

  ];

  #autoLogin.enable = true;
  #autoLogin.username = "ryan";

  networking = {
    hostName = "rydev";
    #networkmanager.enable = true;
    enableIPv6 = true;
  };

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
      timeout = 3;
    };
  };

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "23.11";
}