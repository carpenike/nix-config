{ pkgs, flake-packages, ... }: {
  config = {
    home.packages = with pkgs;
      with flake-packages.${pkgs.system}; [
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
      ];
  };
}