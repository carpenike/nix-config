{ config, lib, ... }:
let
  cfg = config.services.atriumLitellmAdmission;
in
{
  options.services.atriumLitellmAdmission = {
    enable = lib.mkEnableOption "isolated Atrium LiteLLM admission package";
    isolatedHarness = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Explicit acknowledgement that this configuration is an isolated harness.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      description = "Admission package supplied with actual Atrium resolver/profile dependencies.";
    };
    settingsFile = lib.mkOption {
      type = lib.types.str;
      description = "OS-protected runtime settings path; contents are never copied to the Nix store.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.isolatedHarness
          && lib.hasPrefix "/" cfg.settingsFile
          && !(lib.hasPrefix "/nix/store" cfg.settingsFile);
        message = "Atrium admission may be enabled only for the explicitly isolated harness.";
      }
    ];
    environment.systemPackages = [ cfg.package ];
    environment.etc."atrium-n05-isolated-settings-path".text = cfg.settingsFile;
  };
}
