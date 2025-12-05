{ pkgs, ... }: {
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

      # Custom packaged tools
      backup-list
      backup-status
      syncoid-list
    ];
  };
}
