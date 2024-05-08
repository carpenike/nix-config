{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.modules.services.adguardhome;
in
{
  options.modules.services.adguardhome = {
    enable = lib.mkEnableOption "adguardhome";
    package = lib.mkPackageOption pkgs "adguardhome" { };
    settings = lib.mkOption {
      default = {};
      type = lib.types.attrs;
    };
  };

  config = lib.mkIf cfg.enable {
    services.adguardhome = {
      enable = true;
      mutableSettings = false;
      inherit (cfg) settings;
    };
    # insert password before service starts
    # password in sops is unencrypted, so we bcrypt it
    # and insert it as per config requirements
    systemd.services.adguardhome = {
      preStart = lib.mkAfter ''
        HASH=$(cat ${config.sops.secrets."networking/adguardhome/password".path} | ${pkgs.apacheHttpd}/bin/htpasswd -niB "" | cut -c 2-)
        ${pkgs.gnused}/bin/sed -i "s,ADGUARDPASS,$HASH," "$STATE_DIRECTORY/AdGuardHome.yaml"
      '';
    };
  };

}