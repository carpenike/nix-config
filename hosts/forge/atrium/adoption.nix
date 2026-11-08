# The owner's Atrium opt-ins as they stood when Atrium was retired. Forge no
# longer runs Atrium: retired.nix overrides all of this. Kept so the Atrium
# checks (tests/atrium_n03/adopted.nix) still evaluate the adopted host.
{ ... }: {
  imports = [ ./whiskey-egress.nix ];
  services.atriumForge.adoption.models = true;
  services.atriumForge.adoption.native = true;
  services.atriumForge.adoption.whiskey = true;
  services.atriumForge.adoption.whiskeyText = true;
}
