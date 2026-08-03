# hosts/forge/services/signal-api.nix
#
# Signal delivery transport for the household-advisor system.
#
# signal-cli-rest-api runs a dedicated Signal bot account ("Household
# Advisor"). Hermes owns interactive send/receive; homelab-mcp remains a
# send-only future caller for the separate weekly financial pulse work.
#
#   hermes-agent  <->  signal-api container  <->  family Signal group
#                  REST send / WebSocket receive
#
#   homelab-mcp   -->  signal-api container
#                  future send only
#
# The account registration is a ONE-TIME MANUAL PROCEDURE performed by a
# human - see modules/nixos/services/signal-api/RUNBOOK.md. Until that runs,
# the container comes up healthy but has no account and every send returns an
# error. Nothing here depends on registration having happened.
#
# NETWORK EXPOSURE: internal only, and deliberately so. The REST API has no
# authentication of any kind. Do NOT add a Caddy vhost, a Cloudflare Tunnel
# ingress rule, or a LAN port opening for this service. See the security
# model in modules/nixos/services/signal-api/default.nix.
{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceName = "signal-api";
  dataDir = "/var/lib/signal-api";
  dataset = "tank/services/${serviceName}";
  serviceEnabled = config.modules.services.signal-api.enable or false;

  # Dedicated, isolated Podman network. Isolation is what stops every *other*
  # container on forge from reaching the unauthenticated API on its container
  # IP; the iptables guard below covers host processes.
  podmanNetwork = "signal-api";
  podmanSubnet = "10.90.0.0/24";
  podmanGateway = "10.90.0.1";
  consumerBaseUrl = "http://127.0.0.1:${toString config.modules.services.signal-api.port}";
in
{
  config = lib.mkMerge [
    {
      modules.services.signal-api = {
        enable = true;
        inherit dataDir;

        # Native json-rpc mode: one resident signal-cli daemon, sub-second
        # sends. Required for a responsive MCP tool.
        mode = "json-rpc";

        inherit podmanNetwork;

        # Who may talk to the unauthenticated API on this host:
        #   hermes      - interactive Signal send/receive gateway
        #   homelab-mcp - approved future send-only caller (`signal_send`)
        #   gatus       - the liveness check below
        #   root        - operators following the registration runbook
        #
        # RECEIVE CONSUMER INVARIANT: hermes-agent is the only service that
        # may attach to /v1/receive. Never add a second receiver; concurrent
        # consumers contend for messages and can cause loss or duplication.
        localAccess = {
          enable = true;
          subnet = podmanSubnet;
          allowedUsers = [ "root" "hermes" "homelab-mcp" "gatus" ];
        };

        # Crown-jewel state: the account registration keys ARE the bot's
        # Signal identity. Losing them means re-registering the number (new
        # safety numbers for every member, re-joining the group); leaking them
        # means someone else can impersonate the bot.
        backup = forgeDefaults.mkBackupWithTags serviceName [ "signal" "messaging" "forge" ];

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        notifications = {
          enable = true;
          channels.onFailure = [ "system-alerts" ];
          customMessages.failure = ''
            Signal API failed on ${config.networking.hostName}. The weekly
            household pulse cannot be delivered until it recovers.
            Check: journalctl -u podman-signal-api -n 200
          '';
        };
      };

      # Isolated bridge for this container only.
      modules.virtualization.podman.networks.${podmanNetwork} = {
        driver = "bridge";
        subnet = podmanSubnet;
        gateway = podmanGateway;
        # netavark drops traffic between this bridge and every other Podman
        # network. Host <-> container and outbound NAT to Signal's servers are
        # unaffected.
        isolate = true;
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS dataset. 0700 (rather than the factory's 0750) because nothing
      # else has any business reading the account keys - the Restic job reads
      # them from a snapshot clone with CAP_DAC_READ_SEARCH.
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = dataDir;
        mode = "0700";
        properties = {
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };

        protection = {
          class = "critical";
          objectives = {
            onsiteRpoSeconds = 900;
            offsiteRpoSeconds = 86400;
            rtoSeconds = 7200;
          };
          requiredTiers = [
            "local-snapshot"
            "replication"
            "nas-backup"
            "offsite-backup"
            "automated-restore"
          ];
          consistency = "crash-consistent";
          validator = "signal-api-registration";

          # true, despite this being critical data. The service ships with no
          # account at all - the first deployment MUST be able to come up on an
          # empty dataset so a human can run the registration runbook against
          # it. With `false`, preseed finds nothing to restore, refuses to let
          # the container start, and (on the syncoid path) leaves the freshly
          # created dataset renamed to a `-graveyard-<ts>` sibling.
          #
          # The cost is that a disaster recovery which loses every copy starts
          # the container empty and healthy rather than refusing to start:
          # /v1/health answers 204 with or without an account. Sends fail loudly
          # ("User <number> is not registered"), and the runbook's post-restore
          # check is `GET /v1/accounts` - do not treat a green Gatus check as
          # proof the bot still has its identity.
          allowEmptyBootstrap = true;

          notes = ''
            Registration state is not reproducible from any other source: a
            lost dataset means re-registering the VoIP number with Signal and
            having the family group re-add the bot (see the runbook). Hence
            offsite coverage on top of the standard onsite tiers.
          '';
        };
      };

      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset serviceName;

      # Offsite copy to R2. Most forge services stop at the NAS repository;
      # this one is small (a few MB) and unrecoverable, so it also goes
      # offsite - which is what satisfies the "offsite-backup" tier declared
      # above.
      modules.services.backup.restic.jobs."${serviceName}-offsite" = {
        enable = true;
        repository = "r2-offsite";
        paths = [ dataDir ];
        tags = [ serviceName "signal" "offsite" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = dataset;
      };

      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkServiceDownAlert serviceName "SignalApi" "Signal message transport";

      # Liveness check. Gatus runs as the `gatus` user, which is why it is in
      # localAccess.allowedUsers above.
      #
      # /v1/health is a bare `return 204` in the upstream handler - it proves
      # the HTTP server is serving and nothing more. That is exactly what a
      # liveness probe should be, but do not read more into a green check: the
      # account check below is what says the bot still has an identity.
      modules.services.gatus.contributions.${serviceName} = {
        name = "Signal API";
        group = "Infrastructure";
        url = "${consumerBaseUrl}/v1/health";
        interval = "60s";
        conditions = [
          "[STATUS] == 204"
          "[RESPONSE_TIME] < 2000"
        ];
        alerts = [{
          type = "pushover";
          sendOnResolved = true;
          failureThreshold = 3;
          successThreshold = 1;
        }];
      };

      # Consumer-contract check. This is the exact loopback base URL used by
      # homelab-mcp's signal_send tool, through Podman's published-port DNAT
      # and the host UID guard. Do not replace it with the container IP: that
      # address is a recreate-time implementation detail and bypassing the
      # published-port contract would hide the failure mode this check owns.
      modules.services.gatus.contributions."${serviceName}-consumer" = {
        name = "Signal API Consumer Path";
        group = "Infrastructure";
        url = "${consumerBaseUrl}/v1/about";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[BODY].mode == json-rpc"
          "[RESPONSE_TIME] < 2000"
        ];
        alerts = [{
          type = "pushover";
          sendOnResolved = true;
          failureThreshold = 3;
          successThreshold = 1;
        }];
      };

      # Registration check. In json-rpc mode this call goes through the
      # resident signal-cli daemon (`listAccounts`), so a 200 with a non-empty
      # body proves both that the daemon is answering and that the bot account
      # still exists. It is the check that catches the failure mode
      # allowEmptyBootstrap accepts above: a container restored onto an empty
      # dataset, serving 204s, with no identity.
      #
      # EXPECTED TO BE RED until the registration runbook has been run on a new
      # deployment. The body is a JSON array of registered numbers, so the
      # condition compares against the empty array rather than naming the
      # number here (which would put it in the Nix store).
      modules.services.gatus.contributions."${serviceName}-account" = {
        name = "Signal Account";
        group = "Infrastructure";
        url = "${consumerBaseUrl}/v1/accounts";
        interval = "300s";
        conditions = [
          "[STATUS] == 200"
          "[BODY] != []"
        ];
        alerts = [{
          type = "pushover";
          sendOnResolved = true;
          # Deliberately slack: an unregistered bot is a "fix this today"
          # problem, not a wake-someone-up problem, and this must not page
          # during a container restart.
          failureThreshold = 5;
          successThreshold = 1;
        }];
      };
    })
  ];
}
