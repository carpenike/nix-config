{ pkgs
, ...
}:
{
  # Doas instead of sudo
  security.doas.enable = true;
  security.sudo.enable = false;
  # security.doas.wheelNeedsPassword = false;
  # SECURITY TRADEOFF (accepted): passwordless doas + keepEnv for ryan.
  # keepEnv preserves the caller's environment into root (a compromised user
  # env var like PATH/LD_PRELOAD carries into root shells), and noPass means
  # any code running as ryan can escalate. Accepted for a single-admin homelab
  # where hosts are key-only SSH (no passwords) and ryan already owns the keys
  # to everything; the password prompt would add friction, not a boundary.
  security.doas.extraRules = [{
    users = [ "ryan" ];
    keepEnv = true;
    noPass = true;
  }];

  environment.systemPackages = [
    (pkgs.writeScriptBin "sudo" ''exec doas "$@"'')
  ];
}
