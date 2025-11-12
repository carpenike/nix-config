# Declarative Cloudflare Tunnel (cloudflared) module
# Auto-discovers services from Caddy virtualHosts and generates ingress configuration
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.modules.services.cloudflared;

  # Helper function to find all Caddy virtual hosts that have opted into a specific tunnel.
  # This makes Caddy's virtualHosts the single source of truth for web services.
  findTunneledVhosts = tunnelName:
    attrValues (filterAttrs (name: vhost:
      vhost.enable
      && (vhost.cloudflare or null) != null
      && vhost.cloudflare.enable
      && vhost.cloudflare.tunnel == tunnelName
    ) config.modules.services.caddy.virtualHosts);

in
{
  options.modules.services.cloudflared = {
    enable = mkEnableOption "Cloudflare Tunnel (cloudflared) service";

    package = mkOption {
      type = types.package;
      default = pkgs.cloudflared;
      description = "The cloudflared package to use.";
    };

    user = mkOption {
      type = types.str;
      default = "cloudflared";
      description = "User to run the cloudflared service.";
    };

    group = mkOption {
      type = types.str;
      default = "cloudflared";
      description = "Group to run the cloudflared service.";
    };

    tunnels = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          id = mkOption {
            type = types.str;
            description = "The Cloudflare Tunnel UUID.";
            example = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
          };

          credentialsFile = mkOption {
            type = types.path;
            description = "Path to the tunnel credentials JSON file (managed by SOPS).";
            example = literalExpression ''config.sops.secrets."cloudflared/homelab-credentials".path'';
          };

          defaultService = mkOption {
            type = types.str;
            # By default, point to Caddy, which handles all subsequent routing and auth.
            default = "http://127.0.0.1:${toString (config.services.caddy.httpPort or 80)}";
            description = "The default backend service to which all discovered hostnames will be routed.";
          };

          extraConfig = mkOption {
            type = with types; attrsOf (oneOf [ str int bool (listOf (attrsOf str)) ]);
            default = {};
            description = "Extra configuration options to be merged into the generated config.yaml.";
            example = {
              "log-level" = "debug";
            };
          };
        };
      });
      default = {};
      description = "An attribute set of Cloudflare Tunnels to configure and run.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Create a systemd service for each configured tunnel
    systemd.services = mapAttrs' (tunnelName: tunnel:
      let
        # Generate config.yaml for this tunnel
        configFile = pkgs.writeText "${tunnelName}-config.yaml" (builtins.toJSON (
          {
            "credentials-file" = toString tunnel.credentialsFile;

            # Generate ingress rules from Caddy virtual hosts
            ingress =
              let
                vhosts = findTunneledVhosts tunnelName;
                ingressRules = map (vhost: {
                  hostname = vhost.hostName;
                  service = tunnel.defaultService;
                }) vhosts;
              in
                # The last rule must be a catch-all to prevent leaking the origin IP
                ingressRules ++ [ { service = "http_status:404"; } ];
          } // tunnel.extraConfig
        ));
      in
      nameValuePair "cloudflared-${tunnelName}" {
        description = "Cloudflare Tunnel for ${tunnelName}";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" "caddy.service" ]; # Depends on Caddy
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "notify";
          ExecStart = "${cfg.package}/bin/cloudflared tunnel --no-autoupdate --config ${configFile} run ${tunnel.id}";
          Restart = "on-failure";
          RestartSec = "5s";
          User = cfg.user;
          Group = cfg.group;

          # Security hardening
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          NoNewPrivileges = true;
          AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        };
      }
    ) cfg.tunnels;

    # Create user and group for the cloudflared service
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups.${cfg.group} = {};
  };
}
