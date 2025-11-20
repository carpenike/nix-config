{ inputs, ... }:
{
  imports = [
    inputs.nixos-vscode-server.nixosModules.default
  ];

  config.services.vscode-server.enable = true;
}
