{ config, inputs, pkgs, lib, mylib, ... }:
let
  composition = import ../atrium/configuration.nix { inherit config inputs pkgs lib mylib; };
  inherit (composition) runtime;
  cfg = config.services.atriumPwa;
in
{
  config = lib.mkIf config.services.atriumForge.enable (lib.mkMerge [{
    services.atriumPwa = {
      enable = lib.mkDefault true;
      package = inputs.atrium.packages.${pkgs.stdenv.hostPlatform.system}.pwa;
      origin = runtime.endpoints.resolver;
      authority = runtime.identity.authority.id;
      issuer = runtime.identity.authority.issuer;
      clientId = "cc.atrium.browser";
      nativeResources = lib.optional config.services.atriumForge.adoption.whiskey {
        targetOrigin = runtime.endpoints.whiskey;
        resource = config.services.whiskey-whiskey-whiskey.settings.WWW_EXTERNAL_AS_RESOURCE;
      };
    };
  }
    (lib.mkIf cfg.enable {
      services.atriumForge.groupEvidence.clientIds = lib.mkAfter [ cfg.clientId ];
      modules.services.caddy.virtualHosts.atrium.extraConfig = lib.mkBefore ''
        import ${cfg.generated.caddy}
      '';
      assertions = [{
        assertion = cfg.origin + "/resolver" == runtime.identity.authority.audience;
        message = "Atrium browser resource must match the existing resolver authority; never replace its audience.";
      }];
    })]);
}
