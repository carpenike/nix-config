{ inputs
, overlays ? { }
, ...
}:
{
  # Minimal bootstrap system for initial installation
  # Skips all custom modules to avoid compatibility issues with older ISOs
  # Does NOT use overlays to avoid any potential conflicts
  mkNixosBootstrapSystem = system: hostname:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        {
          nixpkgs.hostPlatform = system;
          nixpkgs.config.allowUnfree = true;
          _module.args = {
            inherit inputs system;
          };
        }
        inputs.disko.nixosModules.disko
        # Skip all complex modules for bootstrap - just the host config
        ../hosts/${hostname}
      ];
      specialArgs = {
        inherit inputs hostname;
      };
    };

  mkNixosSystem =
    { system
    , hostname
    , serviceCategories ? null  # null = all categories, list = selective
    }:
    let
      # Import custom library helpers for injection into modules
      mylib = import ./default.nix { lib = inputs.nixpkgs.lib; };

      # Category module paths
      categoryModules = {
        ai = ../modules/nixos/services/_categories/ai.nix;
        auth = ../modules/nixos/services/_categories/auth.nix;
        automotive = ../modules/nixos/services/_categories/automotive.nix;
        backup = ../modules/nixos/services/_categories/backup.nix;
        development = ../modules/nixos/services/_categories/development.nix;
        downloads = ../modules/nixos/services/_categories/downloads.nix;
        home-automation = ../modules/nixos/services/_categories/home-automation.nix;
        infrastructure = ../modules/nixos/services/_categories/infrastructure.nix;
        media = ../modules/nixos/services/_categories/media.nix;
        media-automation = ../modules/nixos/services/_categories/media-automation.nix;
        network = ../modules/nixos/services/_categories/network.nix;
        observability = ../modules/nixos/services/_categories/observability.nix;
        productivity = ../modules/nixos/services/_categories/productivity.nix;
      };

      # Select which service modules to import
      serviceModules =
        if serviceCategories == null then
          # Import all services (backward compatible - uses default.nix which imports all)
          [ ../modules/nixos/services ]
        else
          # Import only selected categories
          map (cat: categoryModules.${cat}) serviceCategories;

      # Select which base module to use
      # When using selective categories, use base.nix (excludes services)
      # When importing all, use default.nix (includes services)
      nixosBaseModule =
        if serviceCategories == null then
          ../modules/nixos           # default.nix includes ./services
        else
          ../modules/nixos/base.nix; # base.nix excludes services
    in
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = builtins.attrValues overlays;
        config = {
          allowUnfree = true;
          allowUnfreePredicate = _: true;
        };
      };
      modules = [
        {
          nixpkgs.hostPlatform = system;
          _module.args = {
            inherit inputs system;
          };
        }
        inputs.disko.nixosModules.disko
        inputs.home-manager.nixosModules.home-manager
        inputs.sops-nix.nixosModules.sops
        inputs.impermanence.nixosModules.impermanence
        {
          home-manager = {
            useUserPackages = true;
            useGlobalPkgs = true;
            sharedModules = [
              inputs.sops-nix.homeManagerModules.sops
              inputs.catppuccin.homeManagerModules.catppuccin
            ];
            extraSpecialArgs = {
              inherit inputs hostname system;
            };
            users.ryan = ../home/ryan;
          };
        }
        ../modules/common
        nixosBaseModule
      ] ++ serviceModules ++ [
        ../hosts/${hostname}
      ];
      specialArgs = {
        inherit inputs hostname mylib;
      };
    };

  mkDarwinSystem = system: hostname:
    inputs.nix-darwin.lib.darwinSystem {
      inherit system;
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = builtins.attrValues overlays;
        config = {
          allowUnfree = true;
          allowUnfreePredicate = _: true;
        };
      };
      modules = [
        {
          nixpkgs.hostPlatform = system;
          _module.args = {
            inherit inputs;
          };
        }
        inputs.home-manager.darwinModules.home-manager
        {
          home-manager = {
            useUserPackages = true;
            useGlobalPkgs = true;
            backupFileExtension = "backup";
            sharedModules = [
              inputs.sops-nix.homeManagerModules.sops
              inputs.nixvim.homeManagerModules.nixvim
              inputs.catppuccin.homeManagerModules.catppuccin
            ];
            extraSpecialArgs = {
              inherit inputs hostname system;
            };
            users.ryan = ../home/ryan;
          };
        }
        ../modules/common
        ../modules/darwin
        ../hosts/${hostname}
      ];
      specialArgs = {
        inherit inputs hostname;
      };
    };
}
