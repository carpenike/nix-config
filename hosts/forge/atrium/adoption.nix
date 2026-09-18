{ ... }: {
  imports = [ ./whiskey-egress.nix ];
  services.atriumForge.adoption.models = true;
  services.atriumForge.adoption.native = true;
  services.atriumForge.adoption.whiskey = true;
  services.atriumForge.adoption.whiskeyText = true;
}
