# Custom packages, that can be defined similarly to ones from nixpkgs
# You can build them using 'nix build .#example' or (legacy) 'nix-build -A example'
{ pkgs ? import <nixpkgs> { }
, ...
} @_inputs:
{
  backup-list = pkgs.callPackage ./backup-list.nix { };
  backup-orchestrator = pkgs.callPackage ./backup-orchestrator.nix { };
  backup-status = pkgs.callPackage ./backup-status.nix { };
  syncoid-list = pkgs.callPackage ./syncoid-list.nix { };
  kubecolor-catppuccin = pkgs.callPackage ./kubecolor-catppuccin.nix { };
  kubectl-browse-pvc = pkgs.callPackage ./kubectl-browse-pvc.nix { };
  kubectl-get-all = pkgs.callPackage ./kubectl-get-all.nix { };
  kubectl-klock = pkgs.callPackage ./kubectl-klock.nix { };
  kubectl-netshoot = pkgs.callPackage ./kubectl-netshoot.nix { };
  kubectl-pgo = pkgs.callPackage ./kubectl-pgo.nix { };
  cooklang-cli = pkgs.callPackage ./cooklang-cli.nix { };
  cooklang-federation = pkgs.callPackage ./cooklang-federation.nix { };
  nvim = pkgs.callPackage ./nvim.nix _inputs;
  shcopy = pkgs.callPackage ./shcopy.nix { };
  # talhelper = inputs.talhelper.packages.${pkgs.system}.default;
  usage = pkgs.callPackage ./usage.nix { };
}
