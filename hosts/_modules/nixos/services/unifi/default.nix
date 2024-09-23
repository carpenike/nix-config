{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.modules.services.unifi;
  unifiTcpPorts = [ 8080 8443 ];
  unifiUdpPorts = [ 3478 ];
in
{
  options.modules.services.unifi = {
    enable = lib.mkEnableOption "unifi";
    credentialsFile = lib.mkOption {
      type = lib.types.path;
    };
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/unifi/data";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.services.podman.enable = true;

    system.activationScripts.makeUnifiDataDir = lib.stringAfter [ "var" ] ''
      mkdir -p "${cfg.dataDir}"
      chown -R 999:999 ${cfg.dataDir}
    '';

    virtualisation.oci-containers.containers = {
      unifi = {
        image = "ghcr.io/jacobalberty/unifi-docker:v8.4.62";
        environment = {
          "TZ" = "America/New_York";
        };
        autoStart = true;
        ports = [ "8080:8080" "8443:8443" "3478:3478/udp" ];
        volumes = [
          "${cfg.dataDir}:/unifi"
        ];
      };
    };
    networking.firewall.allowedTCPPorts = unifiTcpPorts;
    networking.firewall.allowedUDPPorts = unifiUdpPorts;
  };
}