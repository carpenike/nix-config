{ config, lib, pkgs, ... }:
let
  cfg = config.modules.development.languages;
in
{
  options.modules.development.languages = {
    python.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Python development environment";
    };
    nodejs.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Node.js development environment";
    };
    go.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Go development environment";
    };
    rust.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Rust development environment";
    };
  };

  config = {
    home.packages = with pkgs; [ ]
      ++ lib.optionals cfg.python.enable [
      python311
      python311Packages.pip
      python311Packages.black
      python311Packages.flake8
      python311Packages.ipython
      uv # Fast Python package manager (includes uvx)
    ]
      ++ lib.optionals cfg.nodejs.enable [
      nodejs # includes npm and npx
      nodePackages.yarn
    ]
      ++ lib.optionals cfg.go.enable [
      go
      gopls
      gotools
    ]
      ++ lib.optionals cfg.rust.enable [
      rustup
    ];
  };
}
