{
  description = "carpenike's Nix-Config";

  inputs = {
    #################### Official NixOS and HM Package Sources ####################

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable"; # also see 'unstable-packages' overlay at 'overlays/default.nix"

    hardware.url = "github:nixos/nixos-hardware";

    # Flake-parts - Simplify Nix Flakes with the module system
    #
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    # home-manager - home user+dotfile manager
    # https://github.com/nix-community/home-manager
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
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

    # Rust toolchain overlay
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
    };

    # Catppuccin - Soothing pastel theme for Nix
    # https://github.com/catppuccin/nix
    catppuccin = {
      url = "github:catppuccin/nix/v1.0.2";
    };

    # nix-darwin - nix modules for darwin (MacOS)
    # https://github.com/LnL7/nix-darwin
    nix-darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nix-inspect - Interactive tui for inspecting nix configs
    # https://github.com/bluskript/nix-inspect
    nix-inspect = {
      url = "github:bluskript/nix-inspect";
    };

    impermanence.url = "github:nix-community/impermanence";

    # CoachIQ RV monitoring
    coachiq = {
      url = "github:carpenike/coachiq";
    };

    #################### Personal Repositories ####################
  };

  outputs = {
    flake-parts,
    ...
  } @inputs:
  let
    overlays = import ./overlays {inherit inputs;};
    mkSystemLib = import ./lib/mkSystem.nix {inherit inputs overlays;};

    # Aggregate DNS records from all hosts for centralized zone management
    aggregateDnsRecords = import ./lib/dns-aggregate.nix {
      lib = inputs.nixpkgs.lib;
    };
in
  flake-parts.lib.mkFlake {inherit inputs;} {
    systems = [
      "aarch64-darwin"
      "x86_64-linux"
      "aarch64-linux"
    ];
    imports = [];
    flake = {
      # Shell configured with packages that are typically only needed when working on or with nix-config. -- NEEDS TO BE FIXED MAYBE
      # devShells = forAllSystems
      #   (system:
      #     let pkgs = nixpkgs.legacyPackages.${system};
      #     in import ./shell.nix { inherit pkgs; }
      #   );
      #################### NixOS Configurations ####################
      #
      # Building configurations available through `just rebuild` or `nixos-rebuild --flake .#hostname`
      nixosConfigurations = {
        # Bootstrap deployment
        nixos-bootstrap = mkSystemLib.mkNixosSystem "aarch64-linux" "nixos-bootstrap";# overlays flake-packages;
        # Parallels devlab
        rydev =  mkSystemLib.mkNixosSystem "aarch64-linux" "rydev";# overlays flake-packages;
        # Luna
        luna =  mkSystemLib.mkNixosSystem "x86_64-linux" "luna";# overlays flake-packages;
        # Raspberry Pi RV system
        nixpi = mkSystemLib.mkNixosSystem "aarch64-linux" "nixpi";# overlays flake-packages;
      };

      darwinConfigurations = {
        rymac = mkSystemLib.mkDarwinSystem "aarch64-darwin" "rymac";# overlays flake-packages;
      };

      # Aggregated DNS records from all hosts' Caddy virtual hosts
      # View with: nix eval .#allCaddyDnsRecords --raw
      allCaddyDnsRecords = aggregateDnsRecords (
        inputs.self.nixosConfigurations // inputs.self.darwinConfigurations
      );

        # Convenience output that aggregates the outputs for home, nixos.
        # Also used in ci to build targets generally.
        ciSystems = let
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
