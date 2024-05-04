{
  description = "Carpenike's Nix-Config";

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

    #################### Personal Repositories ####################
  };

  outputs = { self, nixpkgs, home-manager, ... } @ inputs:
  let
    inherit (self) outputs;
    forAllSystems = nixpkgs.lib.genAttrs [
      "x86_64-linux"
      #"aarch64-darwin"
    ];
    inherit (nixpkgs) lib;
    configVars = import ./vars { inherit inputs lib; };
    configLib = import ./lib { inherit lib; };
    specialArgs = { inherit inputs outputs configVars configLib nixpkgs; };
  in
  {
    # Custom modules to enable special functionality for nixos or home-manager oriented configs.
    nixosModules = import ./modules/nixos;
    homeManagerModules = import ./modules/home-manager;

    # Custom modifications/overrides to upstream packages.
    overlays = import ./overlays { inherit inputs outputs; };

    # Custom packages to be shared or upstreamed.
    packages = forAllSystems
      (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in import ./pkgs { inherit pkgs; }
      );

    # TODO change this to something that has better looking output rules
    # Nix formatter available through 'nix fmt' https://nix-community.github.io/nixpkgs-fmt
    formatter = forAllSystems
      (system:
        nixpkgs.legacyPackages.${system}.nixpkgs-fmt
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

    nixosConfigurations = let
      isoConfigVars = lib.recursiveUpdate configVars {
        isMinimal = true;
      };
      isoSpecialArgs = {
        inherit inputs outputs configLib;
        configVars = isoConfigVars;
      };
    in {
      # Parallels devlab
      rydev = lib.nixosSystem {
        inherit specialArgs;
        modules = [
          home-manager.nixosModules.home-manager{
            home-manager.extraSpecialArgs = specialArgs;
          }
          ./hosts/rydev
        ];
      };
      # Ryan Macbook Pro M1 Max
      rymac = lib.nixosSystem {
        inherit specialArgs;
        modules = [
          home-manager.nixosModules.home-manager{
            home-manager.extraSpecialArgs = specialArgs;
          }
          ./hosts/rymac
        ];
      };

      # Custom ISO
      #
      # `just iso` - to generate the iso standalone
      # 'just iso-install <drive>` - to generate and copy directly to USB drive
      # `nix build .#nixosConfigurations.iso.config.system.build.isoImage`
      #
      # Generated images will be output to ./results unless drive is specified
      iso = let
        hostVars = {hostName = "iso";};
        hostSpecialArgs = isoSpecialArgs // {inherit hostVars;};
      in lib.nixosSystem {
        specialArgs = hostSpecialArgs;
        modules = [
          #home-manager.nixosModules.home-manager
          #{
            #home-manager.extraSpecialArgs = hostSpecialArgs;
          #}
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          "${nixpkgs}/nixos/modules/installer/cd-dvd/channel.nix"
          ./hosts/iso
        ];
      };
    };
  };
}
