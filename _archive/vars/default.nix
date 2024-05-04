{ inputs, lib }:
{
  username = "ryan";
  domain = inputs.nix-secrets.domain;
  userFullName = inputs.nix-secrets.full-name;
  handle = "carpenike";
  userEmail = inputs.nix-secrets.user-email;
  gitEmail = "ryan@ryanholt.net";
  workEmail = inputs.nix-secrets.work-email;
  networking = import ./networking.nix { inherit lib; };
}