{ lib, config, pkgs, ... }: {
  # The backup tools are built on python311Packages, which Hydra caches for
  # the fleet's 25.11 but not for 26.05 (mx-edge), where they would pull a
  # full Python 3.11 test stack (pandas, matplotlib, mypy) from source.
  options.modules.utilities.backupTools.enable =
    lib.mkEnableOption "the backup-list, backup-status and syncoid-list CLIs"
    // { default = true; };

  config = {
    home.packages = with pkgs; [
      curl
      dust
      envsubst
      findutils
      fish
      gum
      jo
      jq
      vim
      wget
    ] ++ lib.optionals config.modules.utilities.backupTools.enable [
      # Custom packaged tools
      backup-list
      backup-status
      syncoid-list
    ];
  };
}
