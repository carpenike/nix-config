{ lib
, config
, ...
}:
let
  cfg = config.modules.virtualization;
in
{
  options.modules.virtualization = {
    podman = {
      enable = lib.mkEnableOption "Podman containerization support";

      networks = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            driver = lib.mkOption {
              type = lib.types.str;
              default = "bridge";
              description = "Network driver (bridge, host, macvlan, etc.)";
            };
            subnet = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Subnet for the network in CIDR notation (e.g., 172.20.0.0/16)";
            };
            gateway = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Gateway for the network";
            };
            internal = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether this is an internal network (no external connectivity)";
            };
            ipv6 = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable IPv6 for this network";
            };
          };
        });
        default = { };
        description = ''
          Podman networks to create and manage.

          Each network will be created declaratively and made available
          for container services to join via the `podmanNetwork` option.

          Example:
          ```nix
          modules.virtualization.podman.networks = {
            "media-services" = {
              driver = "bridge";
            };
          };
          ```
        '';
      };
    };
  };

  config = lib.mkIf cfg.podman.enable {
    # Enable Podman
    virtualisation.podman = {
      enable = true;
      dockerCompat = false; # Don't create docker alias
      defaultNetwork.settings.dns_enabled = true; # Enable DNS resolution on default network
    };

    # Enable container backend for oci-containers
    virtualisation.oci-containers.backend = "podman";

    # Create networks declaratively using NixOS's built-in option
    # This ensures networks are created before containers that need them
    systemd.services = lib.mapAttrs'
      (networkName: networkConfig:
        lib.nameValuePair "podman-network-${networkName}" {
          description = "Podman network: ${networkName}";
          wantedBy = [ "multi-user.target" ];
          after = [ "podman.service" ];
          requires = [ "podman.service" ];
          script =
            let
              options = lib.concatStringsSep " " (
                [ "--driver=${networkConfig.driver}" ]
                ++ lib.optional (networkConfig.subnet != null) "--subnet=${networkConfig.subnet}"
                ++ lib.optional (networkConfig.gateway != null) "--gateway=${networkConfig.gateway}"
                ++ lib.optional networkConfig.internal "--internal"
                ++ lib.optional networkConfig.ipv6 "--ipv6"
              );
            in
            ''
              ${config.virtualisation.podman.package}/bin/podman network create ${options} ${networkName} || true
            '';
          preStop = ''
            ${config.virtualisation.podman.package}/bin/podman network rm ${networkName} || true
          '';
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
        }
      )
      cfg.podman.networks;
  };
}
