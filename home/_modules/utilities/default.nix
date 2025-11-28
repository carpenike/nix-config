{ pkgs, ... }: {
  config = {
    home.packages = with pkgs; [
      curl
      du-dust
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
    ];
  };
}
