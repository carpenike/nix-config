{
  description = "carpenike's Nix-Config";

  inputs = {
    #################### Official NixOS and HM Package Sources ####################

    nixpkgs.url = "github:NixOS/nixpkgs/release-23.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable"; # also see 'unstable-packages' overlay at 'overlays/default.nix"

    hardware.url = "github:nixos/nixos-hardware";

    home-manager = {
      url = "github:nix-community/home-manager/release-23.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    #################### Utilities ####################

    # Declarative partitioning and formatting
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets management.
    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # vim4LMFQR!
    nixvim = {
      url = "github:nix-community/nixvim/nixos-23.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Rust toolchain overlay
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
    };

    # nix-darwin
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # deploy-rs
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    nix-inspect.url = "github:bluskript/nix-inspect";

    #################### Personal Repositories ####################
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    home-manager,
    nix-darwin,
    nix-inspect,
    sops-nix,
    disko,
    ...
  } @inputs:
  let
    supportedSystems = ["x86_64-linux" "aarch64-darwin" "aarch64-linux"];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    overlays = import ./overlays {inherit inputs;};
    mkSystemLib = import ./lib/mkSystem.nix {inherit inputs;};
    flake-packages = self.packages;

    legacyPackages = forAllSystems (
      system:
        import nixpkgs {
          inherit system;
          overlays = builtins.attrValues overlays;
          config.allowUnfree = true;
        }
    );
  in
  {
    inherit overlays;

    packages = forAllSystems (
      system: let
        pkgs = legacyPackages.${system};
      in
        import ./pkgs {
          inherit pkgs;
          inherit inputs;
        }
    );

    # Shell configured with packages that are typically only needed when working on or with nix-config.
    devShells = forAllSystems
      (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in import ./shell.nix { inherit pkgs; }
      );

    #################### NixOS Configurations ####################
    #
    # Building configurations available through `just rebuild` or `nixos-rebuild --flake .#hostname`

    nixosConfigurations = {
      # Bootstrap deployment
      nixos-bootstrap = inputs.nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs.inputs = inputs;
        modules = [
          disko.nixosModules.disko
          ./hosts/bootstrap/disko-config.nix
          {
            _module.args.disks = [ "/dev/sda" ];
          }
          # ./hosts/_modules/common
          # ./hosts/_modules/nixos
          ./hosts/bootstrap
        ];
      };
      # Parallels devlab
      rydev =  mkSystemLib.mkNixosSystem "aarch64-linux" "rydev" overlays flake-packages;
      
    };
    # Convenience output that aggregates the outputs for home, nixos.
    # Also used in ci to build targets generally.
    ciSystems =
      let
        nixos = nixpkgs.lib.genAttrs
          (builtins.attrNames inputs.self.nixosConfigurations)
          (attr: inputs.self.nixosConfigurations.${attr}.config.system.build.toplevel);
        darwin = nixpkgs.lib.genAttrs
          (builtins.attrNames inputs.self.darwinConfigurations)
          (attr: inputs.self.darwinConfigurations.${attr}.system);
      in
        nixos // darwin;
  } // import ./deploy.nix inputs;
}
