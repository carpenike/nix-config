{
  description = "carpenike's Nix-Config";

  # Binary caches for faster builds
  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://cache.garnix.io"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
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

    # Flake-parts - Simplify Nix Flakes with the module system
    #
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

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

    # nix-inspect - Interactive tui for inspecting nix configs
    # https://github.com/bluskript/nix-inspect
    nix-inspect = {
      url = "github:bluskript/nix-inspect";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Impermanence - does not have a nixpkgs input, pure module flake
    impermanence = {
      url = "github:nix-community/impermanence";
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
      imports = [ ];

      # Per-system outputs (packages, devShells, formatter, checks)
      perSystem = { system, ... }:
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
          # Development shell for working on nix-config
          devShells.default = pkgs.mkShell {
            NIX_CONFIG = "extra-experimental-features = nix-command flakes";
            nativeBuildInputs = with pkgs; [
              # Nix tools
              nix
              home-manager
              nixpkgs-fmt
              statix
              deadnix

              # Version control & CI
              git
              just
              pre-commit

              # Secrets management
              age
              ssh-to-age
              sops

              # Required for pre-commit on Darwin
              libiconv
            ];

            shellHook = ''
              echo "🔧 nix-config development shell"
              echo "   Run 'just' to see available commands"
            '';
          };

          # Documentation shell for MkDocs development
          devShells.docs = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              python312
              python312Packages.mkdocs
              python312Packages.mkdocs-material
              python312Packages.mkdocs-material-extensions
              python312Packages.pymdown-extensions
              python312Packages.mkdocs-minify-plugin
            ];

            shellHook = ''
              echo "📚 Documentation development shell"
              echo "   Run 'mkdocs serve' to preview docs at http://127.0.0.1:8000"
              echo "   Run 'mkdocs build' to build static site"
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
          # Parallels devlab
          rydev = mkSystemLib.mkNixosSystem "aarch64-linux" "rydev"; # overlays flake-packages;
          # Luna
          luna = mkSystemLib.mkNixosSystem "x86_64-linux" "luna"; # overlays flake-packages;
          # Forge - new server system
          forge = mkSystemLib.mkNixosSystem "x86_64-linux" "forge"; # overlays flake-packages;
          # Raspberry Pi RV system
          nixpi = mkSystemLib.mkNixosSystem "aarch64-linux" "nixpi"; # overlays flake-packages;
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
