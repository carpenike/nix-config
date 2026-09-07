{ atrium, nixpkgs }:
let
  inherit (nixpkgs) lib;
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  package = pkgs.callPackage ../../pkgs/atrium-litellm-admission/package.nix {
    python3Packages = pkgs.python312Packages;
    atriumResolver = atrium.packages.x86_64-linux.resolver;
    atriumProfiles = atrium.packages.x86_64-linux.credential-profiles;
  };
  evaluate = settings: (lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      ./module.nix
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
  runtime_gate_evidence = false;
}
