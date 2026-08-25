{ lib
, config
, pkgs
, ...
}:
let
  cfg = config.modules.virtualization;
  externalBridgeNetworks = lib.filterAttrs
    (
      _networkName: networkConfig:
        networkConfig.driver == "bridge" && !networkConfig.internal
    )
    cfg.podman.networks;
  needsIpv4Forwarding = externalBridgeNetworks != { };
  forwardingGuardUnit = "podman-ipv4-forwarding-guard.service";
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
            isolate = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Enable netavark network isolation (`--opt isolate=true`).

                Containers on an isolated network cannot exchange traffic with
                containers on any other Podman network. Host <-> container
                traffic (including published ports) and outbound NAT are
                unaffected.

                NOTE: only applied when the network is first created - the
                creation command is a no-op for an existing network. Remove the
                network (`podman network rm <name>`) to change this.
              '';
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

    boot.kernel.sysctl = lib.mkIf needsIpv4Forwarding {
      "net.ipv4.ip_forward" = lib.mkDefault 1;
    };

    assertions = lib.optional needsIpv4Forwarding {
      assertion = builtins.elem config.boot.kernel.sysctl."net.ipv4.ip_forward" [ 1 true "1" ];
      message = "External Podman bridge networks require net.ipv4.ip_forward=1.";
    };

    # Create networks declaratively using NixOS's built-in option
    # This ensures networks are created before containers that need them
    systemd.services = lib.mkMerge [
      (lib.mapAttrs'
        (networkName: networkConfig:
          lib.nameValuePair "podman-network-${networkName}" {
            description = "Podman network: ${networkName}";
            wantedBy = [ "multi-user.target" ];
            requires = lib.optional
              (
                networkConfig.driver == "bridge" && !networkConfig.internal
              )
              forwardingGuardUnit;
            after = lib.optional
              (
                networkConfig.driver == "bridge" && !networkConfig.internal
              )
              forwardingGuardUnit;
            # The Podman CLI manages networks directly; it does not require the
            # socket-activated API service to be running.
            script =
              let
                options = lib.concatStringsSep " " (
                  [ "--driver=${networkConfig.driver}" ]
                  ++ lib.optional (networkConfig.subnet != null) "--subnet=${networkConfig.subnet}"
                  ++ lib.optional (networkConfig.gateway != null) "--gateway=${networkConfig.gateway}"
                  ++ lib.optional networkConfig.internal "--internal"
                  ++ lib.optional networkConfig.ipv6 "--ipv6"
                  ++ lib.optional networkConfig.isolate "--opt isolate=true"
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
        cfg.podman.networks)

      (lib.mkIf needsIpv4Forwarding {
        podman-ipv4-forwarding-guard = {
          description = "Ensure IPv4 forwarding for external Podman bridges";
          after = [ "systemd-sysctl.service" ];
          wants = [ "systemd-sysctl.service" ];
          script = ''
            forwarding_file=/proc/sys/net/ipv4/ip_forward
            current="$(${pkgs.coreutils}/bin/cat "$forwarding_file")"

            if [[ "$current" != "1" ]]; then
              echo "IPv4 forwarding drifted to $current; restoring net.ipv4.ip_forward=1" >&2
              ${pkgs.procps}/bin/sysctl -q -w net.ipv4.ip_forward=1
            fi

            [[ "$(${pkgs.coreutils}/bin/cat "$forwarding_file")" == "1" ]]
          '';
          serviceConfig = {
            Type = "oneshot";
            CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = false;
            ProtectSystem = "strict";
          };
        };
      })

      (lib.mkIf needsIpv4Forwarding (
        lib.mapAttrs'
          (containerName: _containerConfig:
            lib.nameValuePair "podman-${containerName}" {
              requires = [ forwardingGuardUnit ];
              after = [ forwardingGuardUnit ];
            }
          )
          config.virtualisation.oci-containers.containers
      ))
    ];

    systemd.timers.podman-ipv4-forwarding-guard = lib.mkIf needsIpv4Forwarding {
      description = "Reconcile IPv4 forwarding for external Podman bridges";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "1m";
        AccuracySec = "5s";
        Unit = forwardingGuardUnit;
      };
    };
  };
}
