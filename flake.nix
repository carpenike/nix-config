{
  description = "carpenike's Nix-Config";

  # Binary caches for faster builds
  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://cache.garnix.io"
      "https://carpenike.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      "carpenike.cachix.org-1:96Z6GrfQJkkTr1f6g9z1JCGGG54CjqIRvnrupPlzEPQ="
    ];
  };

  inputs = {
    #################### Official NixOS and HM Package Sources ####################

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable"; # also see 'unstable-packages' overlay at 'overlays/default.nix"

    # nixos-hardware - does not have a nixpkgs input, pure module flake
    hardware = {
      url = "github:nixos/nixos-hardware";
    };

    #################### Common Dependencies (for follows directives) ####################

    # Systems - shared system type definitions
    # Direct input allows other flakes to follow it, reducing lock file duplication
    systems.url = "github:nix-systems/default";

    # Flake-utils - common flake utility functions
    # Direct input allows beads, nixos-vscode-server, etc. to follow
    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };

    # Flake-parts - Simplify Nix Flakes with the module system
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    #################### Core Modules ####################

    # home-manager - home user+dotfile manager
    # https://github.com/nix-community/home-manager
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    #################### Utilities ####################

    # Declarative partitioning and formatting
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # sops-nix - secrets with mozilla sops
    # https://github.com/Mic92/sops-nix
    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NixVim - Configure Neovim with Nix
    # https://github.com/nix-community/nixvim
    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.systems.follows = "systems";
    };

    # VSCode community extensions
    # https://github.com/nix-community/nix-vscode-extensions
    nix-vscode-extensions = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # VSCode Remote SSH server for NixOS hosts
    nixos-vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    # Rust toolchain overlay
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Catppuccin - Soothing pastel theme for Nix
    # https://github.com/catppuccin/nix
    # v1.0.2 does not have a nixpkgs input to follow
    catppuccin = {
      url = "github:catppuccin/nix/v1.0.2";
    };

    # nix-darwin - nix modules for darwin (MacOS)
    # https://github.com/LnL7/nix-darwin
    nix-darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Impermanence - does not have a nixpkgs input, pure module flake
    impermanence = {
      url = "github:nix-community/impermanence";
    };

    # git-hooks.nix - Pre-commit hooks in Nix
    # https://github.com/cachix/git-hooks.nix
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    #################### Personal Repositories ####################
  };

  outputs =
    { flake-parts
    , ...
    } @inputs:
    let
      overlays = import ./overlays { inherit inputs; };
      mkSystemLib = import ./lib/mkSystem.nix { inherit inputs; inherit overlays; };

      # Aggregate DNS records from all hosts for centralized zone management
      aggregateDnsRecords = import ./lib/dns-aggregate.nix {
        lib = inputs.nixpkgs.lib;
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
      imports = [
        inputs.git-hooks.flakeModule
      ];

      # Per-system outputs (packages, devShells, formatter, checks)
      perSystem = { config, system, ... }:
        let
          # Use nixpkgs with our overlays applied
          pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = builtins.attrValues overlays;
            config.allowUnfree = true;
          };

          # Import all custom packages
          allPackages = import ./pkgs { inherit pkgs inputs; };

          # Filter packages to only those available on the current system
          # This prevents errors when checking packages on Darwin that are Linux-only
          availablePackages = inputs.nixpkgs.lib.filterAttrs
            (_name: pkg:
              let
                # Check if package has meta.platforms defined
                hasPlatforms = pkg ? meta && pkg.meta ? platforms;
                # If no platforms specified, assume available everywhere
                # Otherwise check if current system is in the platforms list
                isAvailable = !hasPlatforms ||
                  builtins.elem system pkg.meta.platforms ||
                  # Also check for platform patterns like "x86_64-linux"
                  builtins.any (p: p == system) pkg.meta.platforms;
              in
              isAvailable
            )
            allPackages;
        in
        {
          # Pre-commit hooks configuration (git-hooks.nix)
          # See: https://github.com/cachix/git-hooks.nix
          pre-commit = {
            check.enable = true; # Adds a check to CI
            settings = {
              hooks = {
                # ===== Nix Formatting & Linting =====
                # Matches CI (nix fmt --check)
                nixpkgs-fmt.enable = true;

                statix = {
                  enable = true;
                  settings.config = "statix.toml";
                };
                deadnix = {
                  enable = true;
                  # Exclude generated files from analysis
                  excludes = [ "^pkgs/_sources/generated\\.nix$" ];
                  settings = {
                    # Don't flag standard NixOS module patterns like { config, lib, pkgs, ... }:
                    # These unused args are required for proper nixpkgs callPackage/module semantics
                    noLambdaPatternNames = true;
                  };
                };

                # ===== Shell Script Linting =====
                # Catches common shell scripting errors in backup-orchestrator.sh, etc.
                shellcheck = {
                  enable = true;
                  excludes = [ "^tmp/" ];
                };

                # ===== Python Linting =====
                # Fast linting for scripts/ Python files (ruff is 10-100x faster than flake8)
                ruff = {
                  enable = true;
                  excludes = [ "^tmp/" ];
                };
                # Python formatting (runs after ruff --fix)
                ruff-format = {
                  enable = true;
                  excludes = [ "^tmp/" ];
                };

                # ===== Configuration File Validation =====
                yamllint = {
                  enable = true;
                  settings.configPath = ".github/lint/.yamllint.yaml";
                };
                check-json.enable = true;
                check-toml.enable = true;

                # ===== General File Hygiene =====
                trim-trailing-whitespace.enable = true;
                end-of-file-fixer.enable = true;

                # ===== Security =====
                # Detect secrets before they're committed
                gitleaks = {
                  enable = true;
                  name = "gitleaks";
                  entry = "${pkgs.gitleaks}/bin/gitleaks protect --staged --redact --verbose";
                  pass_filenames = false;
                };
              };

              # Global exclude patterns
              excludes = [
                "^tmp/" # Temporary/scratch files
                "^site/" # Generated mkdocs site
                "^result" # Nix build outputs
              ];
            };
          };

          # Development shell for working on nix-config
          # Tools here are repo-specific; nix/git/home-manager should be system-wide
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              # Nix linting & formatting (pinned to flake.lock)
              nixpkgs-fmt
              statix
              deadnix
              nil # Nix LSP for editor/AI diagnostics

              # Shell & Python linting (for scripts/)
              shellcheck # Shell script static analysis
              ruff # Fast Python linter (replaces flake8/pylint)

              # Security scanning
              gitleaks # Detect hardcoded secrets

              # NixOS deployment & diff tools
              nvd # Diff NixOS generations
              nix-diff # Detailed derivation diffs
              nvfetcher # Update custom package sources
              nix-update # Fix package hashes
              nix-fast-build # Parallel evaluation and builds for CI

              # Nix store inspection & debugging
              nix-tree # TUI to inspect store paths and dependency trees
              nix-du # Disk usage breakdown for Nix store
              nix-index # Find which package provides a file (run nix-index first)
              nurl # Generate Nix fetcher calls from URLs

              # File search & manipulation (for AI assistants)
              fd # Fast file finder
              sd # Simpler sed for search-replace
              tree # Directory structure overview

              # Task runner
              go-task

              # Secrets management (only needed in this repo)
              age
              ssh-to-age
              sops

              # Documentation (mkdocs for this repo's docs/)
              python312Packages.mkdocs
              python312Packages.mkdocs-material
              python312Packages.mkdocs-material-extensions
              python312Packages.pymdown-extensions
              python312Packages.mkdocs-minify-plugin
            ] ++ lib.optionals pkgs.stdenv.isDarwin [
              # Required for some tools on Darwin
              libiconv
            ] ++ lib.optionals pkgs.stdenv.isLinux [
              # NixOS rebuild (for remote deployments from Linux)
              nixos-rebuild
            ];

            shellHook = ''
              ${config.pre-commit.installationScript}
              echo ""
              echo "nix-config devshell"
              echo "  task          - list available commands"
              echo "  mkdocs serve  - preview docs at http://127.0.0.1:8000"
              echo "  pre-commit hooks installed ✓"
            '';
          };

          # Code formatter (nix fmt)
          formatter = pkgs.nixpkgs-fmt;

          # Custom packages - available via 'nix build .#<name>'
          # Filtered to only packages available on the current system
          packages = availablePackages;

          # Checks for CI
          checks = {
            # Statix linter (uses statix.toml for configuration)
            statix = pkgs.runCommand "statix-check" { nativeBuildInputs = [ pkgs.statix ]; } ''
              cd ${./.}
              statix check . --config statix.toml || exit 1
              touch $out
            '';

            # Deadnix - find dead code
            # Exclude auto-generated files from nvfetcher
            deadnix = pkgs.runCommand "deadnix-check" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
              deadnix --fail --exclude pkgs/_sources/generated.nix ${./.} || exit 1
              touch $out
            '';
          };
        };

      flake = {
        #################### NixOS Configurations ####################
        #
        # Building configurations available through `just rebuild` or `nixos-rebuild --flake .#hostname`
        nixosConfigurations = {
          # Bootstrap deployment - uses minimal builder to avoid compatibility issues
          nixos-bootstrap = mkSystemLib.mkNixosBootstrapSystem "x86_64-linux" "nixos-bootstrap";
          # Parallels devlab - minimal dev environment
          rydev = mkSystemLib.mkNixosSystem {
            system = "aarch64-linux";
            hostname = "rydev";
            serviceCategories = [
              "infrastructure"
              "observability"
            ];
          };
          # Luna - DNS/network infrastructure server
          luna = mkSystemLib.mkNixosSystem {
            system = "x86_64-linux";
            hostname = "luna";
            serviceCategories = [
              "auth"
              "development"
              "infrastructure"
              "network"
              "observability"
            ];
          };
          # Forge - main homelab server (all categories)
          forge = mkSystemLib.mkNixosSystem {
            system = "x86_64-linux";
            hostname = "forge";
            serviceCategories = [
              "ai"
              "auth"
              "automotive"
              "backup"
              "development"
              "downloads"
              "home-automation"
              "infrastructure"
              "media"
              "media-automation"
              "network"
              "observability"
              "productivity"
            ];
          };
          # NAS-0 - Primary bulk storage NAS (117TB) - not yet deployed
          nas-0 = mkSystemLib.mkNixosSystem { system = "x86_64-linux"; hostname = "nas-0"; };
          # NAS-1 - Secondary NAS / Backup target - not yet deployed
          nas-1 = mkSystemLib.mkNixosSystem { system = "x86_64-linux"; hostname = "nas-1"; };
          # Raspberry Pi RV system
          nixpi = mkSystemLib.mkNixosSystem {
            system = "aarch64-linux";
            hostname = "nixpi";
            serviceCategories = [
              "infrastructure"
              "observability"
            ];
          };
        };

        darwinConfigurations = {
          rymac = mkSystemLib.mkDarwinSystem "aarch64-darwin" "rymac"; # overlays flake-packages;
        };

        # Aggregated DNS records from all hosts' Caddy virtual hosts
        # View with: nix eval .#allCaddyDnsRecords --raw
        allCaddyDnsRecords = aggregateDnsRecords (
          inputs.self.nixosConfigurations // inputs.self.darwinConfigurations
        );

        # Convenience output that aggregates the outputs for home, nixos.
        # Also used in ci to build targets generally.
        ciSystems =
          let
            nixos =
              inputs.nixpkgs.lib.genAttrs
                (builtins.attrNames inputs.self.nixosConfigurations)
                (attr: inputs.self.nixosConfigurations.${attr}.config.system.build.toplevel);
            darwin =
              inputs.nixpkgs.lib.genAttrs
                (builtins.attrNames inputs.self.darwinConfigurations)
                (attr: inputs.self.darwinConfigurations.${attr}.system);
          in
          nixos // darwin;
      };
    };
}
