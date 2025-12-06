{ pkgs
, inputs
, lib
, config
, ...
}:
let
  cfg = config.modules.development;
  # nix-inspect uses nix-cargo-integration which has issues on aarch64
  isX86 = pkgs.stdenv.hostPlatform.isx86_64;
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
    ]) ++
    (lib.optionals isX86 [
      inputs.nix-inspect.packages.${pkgs.stdenv.hostPlatform.system}.default
    ]);
  };
}
