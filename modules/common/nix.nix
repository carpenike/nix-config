{ inputs
, lib
, ...
}:
{
  nix = {
    settings = {
      trusted-substituters = [
        "https://carpenike.cachix.org"
        "https://nix-community.cachix.org"
        "https://cache.garnix.io"
        "https://numtide.cachix.org"
      ];

      trusted-public-keys = [
        "carpenike.cachix.org-1:96Z6GrfQJkkTr1f6g9z1JCGGG54CjqIRvnrupPlzEPQ="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
        "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
      ];
      # Fallback quickly if substituters are not available.
      connect-timeout = 5;

      # Enable flakes
      experimental-features = [
        "nix-command"
        "flakes"
      ];

      warn-dirty = false;

      # Parallel builds - use all available cores
      max-jobs = "auto";
      cores = 0; # 0 = use all cores per derivation

      # HTTP/2 for faster cache downloads
      http2 = true;

      # Continue building other derivations on failure
      keep-going = true;

      # The default at 10 is rarely enough.
      log-lines = lib.mkDefault 25;

      # Avoid disk full issues
      max-free = lib.mkDefault (1000 * 1000 * 1000);
      min-free = lib.mkDefault (128 * 1000 * 1000);

      # Avoid copying unnecessary stuff over SSH
      builders-use-substitutes = true;
    };

    # Pin nixpkgs registry to flake input for faster `nix shell nixpkgs#<pkg>` etc.
    # Without this, nix downloads a fresh nixpkgs tarball instead of using the flake's pinned version
    registry.nixpkgs.flake = inputs.nixpkgs;

    # Add nixpkgs input to NIX_PATH for legacy nix-shell compatibility
    nixPath = [ "nixpkgs=${inputs.nixpkgs.outPath}" ];

    # garbage collection
    gc = {
      automatic = true;
      options = "--delete-older-than 30d";
    };
  };
}
