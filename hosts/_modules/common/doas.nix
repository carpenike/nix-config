{
  pkgs,
  ...
}:
{
  # Doas instead of sudo
  security.doas.enable = true;
  security.sudo.enable = false;
  # security.doas.wheelNeedsPassword = false;
  security.doas.extraRules = [{
    users = [ "ryan" ];
    keepEnv = true;
    noPass = true;
  }];

  environment.systemPackages = [
    (pkgs.writeScriptBin "sudo" ''exec doas "$@"'')
  ];
}
