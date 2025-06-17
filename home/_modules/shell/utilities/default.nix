{ pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    any-nix-shell
    binutils
    coreutils
    curl
    du-dust
    envsubst
    findutils
    fish
    gawk
    gnused
    gum
    jo
    jq
    shcopy
    tmux
    vim
    wget
    yq-go

    # Add commonly needed tools that were removed from Homebrew
    ripgrep      # Fast grep alternative
    sops         # Secret operations
    go-task      # Task runner
  ] ++ lib.optionals pkgs.stdenv.isDarwin [
    mas          # Mac App Store CLI (Darwin only)
  ];
}
