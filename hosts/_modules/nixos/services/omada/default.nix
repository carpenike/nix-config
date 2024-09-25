{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.modules.services.omada;
  omadaTcpPorts = [ 8043 8843 29814 ];
  omadaUdpPorts = [ 29810  ];
in
{
  options.modules.services.omada = {
    enable = lib.mkEnableOption "omada";
    credentialsFile = lib.mkOption {
      type = lib.types.path;
    };
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/omada/data";
    };
    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/omada/log";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.services.podman.enable = true;

    system.activationScripts.makeOmadaDataDir = lib.stringAfter [ "var" ] ''
      mkdir -p "${cfg.dataDir}"
      chown -R 999:999 ${cfg.dataDir}
    '';
    system.activationScripts.makeOmadaLogDir = lib.stringAfter [ "var" ] ''
      mkdir -p "${cfg.logDir}"
      chown -R 999:999 ${cfg.logDir}
    '';

    virtualisation.oci-containers.containers = {
      omada = {
        image = "docker.io/mbentley/omada-controller:5.14";
        environment = {
          "TZ" = "America/New_York";
        };
        autoStart = true;
        ports = [ "8043:8043" "8843:8843" "29814:29814" "29810:29810/udp"  ];
        volumes = [
          "${cfg.dataDir}:/opt/tplink/EAPController/data"
          "${cfg.logDir}:/opt/tplink/EAPController/logs"
        ];
      };
    };
    networking.firewall.allowedTCPPorts = omadaTcpPorts;
    networking.firewall.allowedUDPPorts = omadaUdpPorts;
  };
}
