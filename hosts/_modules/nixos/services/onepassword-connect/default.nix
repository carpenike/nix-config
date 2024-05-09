{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.modules.services.onepassword-connect;
  apiPort = 8080;
  syncPort = 8081;
in
{
  options.modules.services.onepassword-connect = {
    enable = lib.mkEnableOption "onepassword-connect";
    credentialsFile = lib.mkOption {
      type = lib.types.path;
    };
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/onepassword-connect/data";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.services.podman.enable = true;

    system.activationScripts.makeOnePasswordConnectDataDir = lib.stringAfter [ "var" ] ''
      mkdir -p "${cfg.dataDir}"
      chown -R 999:999 ${cfg.dataDir}
    '';

    virtualisation.oci-containers.containers = {
      onepassword-connect-api = {
        image = "docker.io/1password/connect-api:1.7.2";
        autoStart = true;
        ports = [ "8000:8080" ];
        volumes = [
          "${cfg.credentialsFile}:/home/opuser/.op/1password-credentials.json"
          "${cfg.dataDir}:/home/opuser/.op/data"
        ];
      };

      onepassword-connect-sync = {
        image = "docker.io/1password/connect-sync:1.7.2";
        autoStart = true;
        volumes = [
          "${cfg.credentialsFile}:/home/opuser/.op/1password-credentials.json"
          "${cfg.dataDir}:/home/opuser/.op/data"
        ];
      };
    };
    networking.firewall.allowedTCPPorts = [ apiPort syncPort ];
  };
}