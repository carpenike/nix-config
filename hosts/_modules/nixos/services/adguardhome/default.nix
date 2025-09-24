{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.modules.services.adguardhome;
  adguardUser = "adguardhome";
in
{
  imports = [ ./shared.nix ]; # Import the shared options module

  options.modules.services.adguardhome = {
    enable = lib.mkEnableOption "adguardhome";
    package = lib.mkPackageOption pkgs "adguardhome" { };
    settings = lib.mkOption {
      default = {};
      type = lib.types.attrs;
    };
    mutableSettings = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to allow settings to be changed via web UI.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.adguardhome = {
      enable = true;
      inherit (cfg) mutableSettings;
      inherit (cfg) settings;
    };
    # add user, needed to access the secret
    users.users.${adguardUser} = {
      isSystemUser = true;
      group = adguardUser;
    };
    users.groups.${adguardUser} = { };
    # insert password before service starts
    # password in sops is unencrypted, so we bcrypt it
    # and insert it as per config requirements
    systemd.services.adguardhome = {
      preStart = lib.mkAfter ''
        HASH=$(cat ${config.sops.secrets."networking/adguardhome/password".path} | ${pkgs.apacheHttpd}/bin/htpasswd -binBC 12 "" | cut -c 2-)
        ${pkgs.gnused}/bin/sed -i "s,ADGUARDPASS,$HASH," "$STATE_DIRECTORY/AdGuardHome.yaml"
      '';
      serviceConfig.User = adguardUser;
    };

    # Note: firewall ports now managed by shared.nix when shared config is used
  };

}
