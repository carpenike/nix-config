{ pkgs
, lib
, config
, ...
}:
let
  cfg = config.modules.development;
in
{
  config = lib.mkIf cfg.enable {
    home.packages = (with pkgs; [
      cue
      nixd
      nixfmt-rfc-style
      nodePackages.prettier
      pre-commit
      shellcheck
      shfmt
      yamllint
      unstable.helm-ls
      unstable.minio-client
      # Beads - Memory system and issue tracker for AI coding agents
      # Provides 'bd' CLI for tracking long-horizon tasks across sessions
      beads
    ]);
  };
}
