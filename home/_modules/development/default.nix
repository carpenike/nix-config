{ lib
, ...
}:
{
  imports = [
    ./utilities
    ./languages
  ];

  options.modules.development = {
    enable = lib.mkEnableOption "development";
  };
}
