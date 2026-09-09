{ atrium, nixpkgs }:
let
  host = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = { inherit atrium; };
    modules = [ ./host.nix ];
  };
  cfg = host.config;
  service = cfg.systemd.services.atrium-reconciler;
  package = atrium.packages.x86_64-linux.atrium-litellm-controller;
  checks = {
    assertions = nixpkgs.lib.all (assertion: assertion.assertion) cfg.assertions;
    isolated = cfg.networking.hostName == "atrium-n04-fixture";
    noPublicPorts = cfg.networking.firewall.allowedTCPPorts == [ ];
    noResolver = !cfg.services.atrium.runtime.resolver.enable;
    noImplicitInitialization = service.preStart == ""
      && builtins.head cfg.services.atrium.runtime.reconciler.arguments == "reconcile";
    appPackage = cfg.services.atrium.runtime.reconciler.package == package;
    nativeController = nixpkgs.lib.hasPrefix "${package}/bin/atrium-litellm-controller" service.serviceConfig.ExecStart
      && nixpkgs.lib.hasInfix "reconcile" service.serviceConfig.ExecStart;
    persistentOwnership = service.serviceConfig.StateDirectory == "atrium-reconciler"
      && !service.serviceConfig.DynamicUser;
    nonRoot = service.serviceConfig.User == "atrium-reconciler" && cfg.users.users.atrium-reconciler.uid == 65430;
    separatedConsumer = cfg.users.users.atrium-consumer-fixture.uid == 65431;
    hardened = service.serviceConfig.NoNewPrivileges && service.serviceConfig.ProtectSystem == "strict";
    credentialReferenceOnly = service.serviceConfig.LoadCredential == [ "management:/run/atrium-n04-input/management" ];
    timer = cfg.systemd.timers.atrium-reconciler.timerConfig.Unit == "atrium-reconciler.service";
  };
in
assert nixpkgs.lib.all (passed: passed) (builtins.attrValues checks);
{
  inherit checks;
  deployment_only = true;
  runtime_gate_evidence = false;
}
