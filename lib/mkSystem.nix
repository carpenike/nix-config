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
    , extraModules ? [ ]        # extra modules (e.g. sd-image builder)
    , extraHomeModules ? [ ]    # feature modules shared with Home Manager
    }:
    let
      # Import custom library helpers for injection into modules
      mylib = import ./default.nix { lib = inputs.nixpkgs.lib; };
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
              inputs.sops-nix.homeModules.sops
              inputs.catppuccin.homeManagerModules.catppuccin
            ] ++ extraHomeModules;
            extraSpecialArgs = {
              inherit inputs hostname system;
            };
            users.ryan = ../home/ryan;
          };
        }
        ../modules/common
        # All NixOS modules including every service module. Service modules are
        # enable-gated and default off, so importing them everywhere is free:
        # measured eval cost of all 87 vs a 2-category subset is identical
        # (within noise) — selective category loading was removed accordingly.
        ../modules/nixos
        ../hosts/${hostname}
      ] ++ extraModules;
      specialArgs = {
        inherit inputs hostname mylib;
      };
    };

  mkDarwinSystem =
    { system
    , hostname
    , extraModules ? [ ]
    , extraHomeModules ? [ ]
    }:
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
              inputs.sops-nix.homeModules.sops
              inputs.nixvim.homeModules.nixvim
              inputs.catppuccin.homeManagerModules.catppuccin
            ] ++ extraHomeModules;
            extraSpecialArgs = {
              inherit inputs hostname system;
            };
            users.ryan = ../home/ryan;
          };
        }
        ../modules/common
        ../modules/darwin
      ] ++ extraModules ++ [
        ../hosts/${hostname}
      ];
      specialArgs = {
        inherit inputs hostname;
      };
    };
}
