{ atrium, nixpkgs }:
let
  inherit (nixpkgs) lib;
  package = atrium.packages.x86_64-linux.atrium-litellm-admission;
  evaluate = settings: (lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      atrium.nixosModules.litellm-admission
      {
        services.atriumLitellmAdmission = {
          inherit package;
          isolatedHarness = true;
          settingsFile = "/run/atrium-n05-fixture/settings.json";
        } // settings;
        networking.hostName = "atrium-n05-fixture";
        networking.firewall.allowedTCPPorts = [ ];
        boot.loader.grub.enable = false;
        fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
        system.stateVersion = "25.11";
      }
    ];
  }).config;
  enabledWith = settings: evaluate ({ enable = true; } // settings);
  enabled = enabledWith { };
  disabled = evaluate { };
  valid = cfg: lib.all (assertion: assertion.assertion) cfg.assertions;
  checks = {
    isolated = valid enabled;
    requiresIsolation = !(valid (enabledWith { isolatedHarness = false; }));
    refusesStoreSettings = !(valid (enabledWith { settingsFile = "/nix/store/not-a-runtime-input"; }));
    refusesRelativeSettings = !(valid (enabledWith { settingsFile = "relative.json"; }));
    packageExport = lib.elem package enabled.environment.systemPackages;
    appPackage = enabled.services.atriumLitellmAdmission.package == package;
    referenceOnly = enabled.environment.etc."atrium-n05-isolated-settings-path".text
      == "/run/atrium-n05-fixture/settings.json";
    disabledByDefault = !(disabled.environment.etc ? "atrium-n05-isolated-settings-path");
    noPublicPorts = enabled.networking.firewall.allowedTCPPorts == [ ];
    noGatewayActivation = !(enabled.systemd.services ? litellm);
  };
in
assert lib.all (passed: passed) (builtins.attrValues checks);
{
  inherit checks;
  deployment_only = true;
  runtime_gate_evidence = false;
}
