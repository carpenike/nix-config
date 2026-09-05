# hosts/forge/services/copilot-api.nix
#
# copilot-api on forge: the household GitHub Copilot subscription exposed as
# an Anthropic- and OpenAI-compatible inference endpoint. Reusable module:
# modules/nixos/services/copilot-api/default.nix (read its header first).
#
# Who talks to it
# ---------------
#   LiteLLM (default Podman net)   → http://host.containers.internal:4141 (bearer key)
#   Claude Code / tools on the LAN → https://copilot.holthome.net (bearer key)
#
# Every client presents the copilot-api client key. With no `apiKeysFile`
# set, the module generates one on first start:
#
#     sudo cat /var/lib/copilot-api/api-key
#
# Claude Code on a workstation then needs only:
#
#     ANTHROPIC_BASE_URL=https://copilot.holthome.net
#     ANTHROPIC_AUTH_TOKEN=<that key>
#     ANTHROPIC_MODEL=<a model id from GET /v1/models>
#
# First deploy
# ------------
# The unit stays inactive (ConditionFileNotEmpty) until the one-time GitHub
# device login has been completed on forge:
#
#     sudo copilot-api-login
#     sudo systemctl start podman-copilot-api
#
# Expect the CopilotApiServiceDown alert until that is done.
#
# Exposure: loopback publish + Caddy on LAN addresses only; never added to
# the Cloudflare tunnel. Unsupported use of a Copilot subscription — see the
# module header for the abuse-detection caveat.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceName = "copilot-api";
  serviceEnabled = config.modules.services.${serviceName}.enable or false;
  serviceDomain = "copilot.${config.networking.domain}";
  listenPort = 4141;
in
{
  config = lib.mkMerge [
    {
      modules.services.copilot-api = {
        enable = true;

        # Pin container image (Renovate will update)
        image = "ghcr.io/caozhiyuan/copilot-api:v2.3.16@sha256:b85f6e13517513e847ea77efcb098cc9a368e6b5898c3fd129eafbb3eef7237d";

        # 4141 is upstream's default and unused elsewhere on forge.
        port = listenPort;

        # Default Podman network (no podmanNetwork): LiteLLM lives there too
        # because PostgreSQL only listens on that bridge. LiteLLM reaches this
        # service as http://host.containers.internal:4141 through the extra
        # publish below; the address is host-local to the bridge, and the app
        # requires the bearer key on every inference route regardless.
        bridgePublishAddress = "10.88.0.1";

        # Client keys: leave null to have the module generate one, or point
        # at a sops secret with one key per line, e.g.
        #   apiKeysFile = config.sops.secrets."copilot-api/api-keys".path;
        # (add the matching entry to secrets.nix + secrets.sops.yaml first).
        apiKeysFile = null;

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          # No caddySecurity: machine clients only; the app enforces bearer
          # keys on every inference route. Close the two surfaces that are
          # not key-protected or are admin-only, so they exist only on forge.
          extraConfig = ''
            @blocked path /usage-viewer* /admin*
            respond @blocked 404
          '';
        };

        backup = forgeDefaults.mkBackupWithSnapshots serviceName;
        notifications.enable = true;
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # The token is re-creatable by a human in two minutes, but the point of
      # keeping it is not needing the human: a restore that brings the token
      # back brings the service back with it.
      modules.storage.datasets.services.${serviceName}.protection = {
        class = "standard";
        objectives = {
          onsiteRpoSeconds = 86400;
          offsiteRpoSeconds = null;
          rtoSeconds = 28800;
        };
        requiredTiers = [
          "local-snapshot"
          "replication"
          "nas-backup"
          "automated-restore"
        ];
        consistency = "crash-consistent";
        validator = null;
        # Empty on first deploy by design: the device login populates it.
        allowEmptyBootstrap = true;
      };

      modules.backup.sanoid.datasets."tank/services/${serviceName}" =
        forgeDefaults.mkSanoidDataset serviceName;

      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkServiceDownAlert serviceName "CopilotApi" "GitHub Copilot inference proxy";

      # Black-box check against the unauthenticated liveness route. Probing
      # loopback rather than the vhost keeps the check independent of Caddy.
      modules.services.gatus.contributions.${serviceName} = {
        name = "Copilot API";
        group = "Infrastructure";
        url = "http://127.0.0.1:${toString listenPort}/";
        interval = "300s";
        conditions = [ "[STATUS] == 200" "[BODY] == Server running" ];
      };
    })
  ];
}
