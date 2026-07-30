# modules/nixos/services/signal-api/default.nix
#
# signal-api - Signal messenger transport (bbernhard/signal-cli-rest-api)
#
# A thin REST wrapper around signal-cli. It exists so other homelab services
# can send Signal messages as a dedicated bot account without embedding
# signal-cli themselves. On forge the only intended consumer is homelab-mcp
# (its future `signal_send` tool).
#
# Reference: https://github.com/bbernhard/signal-cli-rest-api
# API docs:  https://bbernhard.github.io/signal-cli-rest-api/
# Runbook:   ./RUNBOOK.md (one-time human registration procedure)
#
# SECURITY MODEL - READ BEFORE CHANGING ANYTHING ABOUT NETWORKING
# ---------------------------------------------------------------
# The REST API has NO AUTHENTICATION WHATSOEVER. Anything that can open a
# TCP connection to it can send Signal messages as the bot, read the bot's
# messages, list its groups, or unregister the account. Three layers keep
# that surface closed:
#
#   1. The published port is bound to 127.0.0.1 only (see extraConfig). It is
#      never reachable from the LAN, and it must NEVER be given a Caddy vhost
#      or a Cloudflare Tunnel ingress rule.
#   2. The container runs alone on an *isolated* Podman network, so no other
#      container on the host can reach its container IP directly.
#   3. An iptables guard in the filter OUTPUT chain rejects connections to the
#      API from every local UID except the ones named in
#      `localAccess.allowedUsers` (see the localAccess option below).
#
# The registration state under dataDir (account keys, identity keys, session
# state) is the crown jewel: possession of it *is* the bot's Signal identity.
# It is stored on its own ZFS dataset with 0700 permissions and is expected to
# be snapshotted, replicated and backed up by the host configuration.
#
# Factory-based implementation (see lib/service-factory.nix).
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

let
  serviceIds = mylib.serviceUids.signal-api;

  # The image always listens on 8080 inside the container (Dockerfile
  # `ENV PORT=8080`); cfg.port is the host-side loopback port.
  containerPort = 8080;
in
mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "signal-api";
  description = "Signal REST API";

  spec = {
    port = 8484;
    inherit containerPort;

    # Pinned by tag + digest.
    #
    # BUMP THIS PERIODICALLY. signal-cli-rest-api vendors signal-cli, which
    # implements an unversioned, server-driven protocol: when Signal changes
    # the protocol or retires a client version, an old image stops being able
    # to send and the only fix is a newer image. Treat a "sending suddenly
    # broke" incident as an image-age problem first.
    #   Upstream releases: https://github.com/bbernhard/signal-cli-rest-api/releases
    image = "bbernhard/signal-cli-rest-api:0.100@sha256:2399d449123cdad56c4d859277e3b9127e1a00c4d2ab4601c239882609286cf8";

    operationalProfile = "infrastructure";
    displayName = "Signal API";
    function = "messaging_transport";

    # The image ships curl and its own HEALTHCHECK hits this endpoint.
    # /v1/health answers 204 No Content, so the factory's default
    # "expect HTTP 200" probe would report a permanently unhealthy container.
    healthCommand = "curl -f -s -o /dev/null http://127.0.0.1:${toString containerPort}/v1/health || exit 1";
    # A cold JVM + signal-cli daemon start is slow; don't count health
    # failures until it has had a chance to come up.
    startPeriod = "120s";

    # Small files (account json, protocol store, per-recipient session state).
    zfsRecordSize = "16K";

    # json-rpc mode = resident JVM, which upstream flags as the mode with
    # "increased" memory use. 1G is a starting estimate, not a measurement -
    # check `podman stats signal-api` after a few weeks and tighten it. Do not
    # cut it aggressively: upstream traces "User <number> is not registered"
    # errors to a resource-starved container.
    resources = {
      memory = "1G";
      memoryReservation = "512M";
      cpus = "2.0";
    };

    # The entrypoint must start as root: it usermod/groupmods the in-image
    # `signal-api` account to SIGNAL_CLI_UID/GID, chowns the config dir, then
    # drops privileges with setpriv before exec'ing the server. The PUID/PGID
    # variables the factory injects for runAsRoot containers are replaced with
    # the SIGNAL_CLI_* equivalents in extraConfig below.
    runAsRoot = true;

    # State lives at the signal-cli config dir, not /config.
    skipDefaultConfigMount = true;
    volumes = cfg': [
      "${cfg'.dataDir}:/home/.local/share/signal-cli:rw"
    ];
  };

  extraOptions = {
    uid = lib.mkOption {
      type = lib.types.int;
      default = serviceIds.uid;
      description = "UID for the signal-api service user (from lib/service-uids.nix).";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = serviceIds.gid;
      description = "GID for the signal-api service group (from lib/service-uids.nix).";
    };

    mode = lib.mkOption {
      type = lib.types.enum [ "json-rpc" "json-rpc-native" "native" "normal" ];
      default = "json-rpc";
      description = ''
        signal-cli execution mode.

        `json-rpc` keeps a single signal-cli JVM daemon resident instead of
        spawning a JVM per request - the difference between a multi-second and
        a sub-second send, which matters because the caller is an interactive
        MCP tool. The cost is a permanently resident JVM (see `resources`).

        `normal`/`native` fork a process per request; `json-rpc-native` uses
        the GraalVM build of signal-cli as the daemon (lower memory, but
        upstream considers it less stable).
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "debug" "info" "warn" "error" ];
      default = "info";
      description = "LOG_LEVEL passed to the container.";
    };

    # ---------------------------------------------------------------------
    # Local access control
    # ---------------------------------------------------------------------
    localAccess = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Install an iptables guard restricting which local users may open a
          connection to the unauthenticated REST API.

          Disabling this leaves every process on the host able to send Signal
          messages as the bot. Only turn it off while debugging.
        '';
      };

      allowedUsers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "root" ];
        example = [ "root" "homelab-mcp" "gatus" ];
        description = ''
          Local user accounts permitted to reach the API. Everything else gets
          a TCP reset.

          `root` is listed by default because it can trivially bypass a UID
          match anyway (setuid, nsenter, podman exec), and the registration
          runbook drives the API with curl as root.
        '';
      };

      subnet = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "10.90.0.0/24";
        description = ''
          CIDR of the Podman network this container runs on.

          The guard matches the *post-DNAT* destination: by the time a packet
          reaches the filter OUTPUT chain, Podman's hostport DNAT has already
          rewritten 127.0.0.1:<port> to <containerIP>:${toString containerPort}. Matching
          the network's subnet therefore covers both the published loopback
          port and any direct connection to the container IP.
        '';
      };
    };

    # No Prometheus endpoint upstream - liveness is covered by the container
    # healthcheck plus the host's Gatus check against /v1/health.
    metrics = lib.mkOption {
      type = lib.types.nullOr mylib.types.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration (signal-api exposes no metrics endpoint)";
    };
  };

  extraConfig = cfg': {
    assertions = lib.optionals cfg'.localAccess.enable (
      [
        {
          assertion = cfg'.localAccess.subnet != null;
          message = ''
            modules.services.signal-api.localAccess.enable requires
            localAccess.subnet to be set to the CIDR of the Podman network the
            container runs on (see modules.virtualization.podman.networks).
          '';
        }
        {
          assertion = cfg'.localAccess.allowedUsers != [ ];
          message = "modules.services.signal-api.localAccess.allowedUsers must not be empty (that would block every caller, including the Gatus liveness check).";
        }
        {
          assertion = config.networking.firewall.enable;
          message = "modules.services.signal-api.localAccess.enable requires networking.firewall.enable (the guard is installed via firewall extraCommands).";
        }
      ]
      ++ map
        (user: {
          assertion = config.users.users ? ${user};
          message = "modules.services.signal-api.localAccess.allowedUsers references unknown user '${user}'; iptables would fail to resolve it at firewall start.";
        })
        cfg'.localAccess.allowedUsers
    );

    virtualisation.oci-containers.containers.signal-api = {
      # Replace the factory's LinuxServer.io-style PUID/PGID/UMASK trio with
      # the variables this image actually reads.
      environment = lib.mkForce {
        TZ = cfg'.timezone;
        MODE = cfg'.mode;
        LOG_LEVEL = cfg'.logLevel;
        # The entrypoint remaps its internal `signal-api` account to these
        # ids, so everything written to the mounted dataset is owned by the
        # host service user.
        SIGNAL_CLI_UID = toString cfg'.uid;
        SIGNAL_CLI_GID = toString cfg'.gid;
        # This bot never receives attachments/stories/stickers; not
        # downloading them keeps the dataset small and the crown-jewel
        # backup cheap.
        JSON_RPC_IGNORE_ATTACHMENTS = "true";
        JSON_RPC_IGNORE_STORIES = "true";
        JSON_RPC_IGNORE_STICKERS = "true";
      };

      # Loopback only. See the security model at the top of this file.
      ports = lib.mkForce [
        "127.0.0.1:${toString cfg'.port}:${toString containerPort}"
      ];
    };

    # ---------------------------------------------------------------------
    # iptables guard (see localAccess above)
    #
    # A dedicated chain keeps the rules idempotent across firewall reloads:
    # create-if-missing, flush, repopulate, and jump to it from OUTPUT only
    # once. NixOS itself installs nothing in filter OUTPUT and netavark only
    # touches nat/FORWARD, so position 1 stays position 1.
    # ---------------------------------------------------------------------
    networking.firewall = lib.mkIf cfg'.localAccess.enable (
      let
        chain = "signal-api-guard";
        jumpMatch = "-p tcp -d ${cfg'.localAccess.subnet} --dport ${toString containerPort} -j ${chain}";
        allowRules = lib.concatMapStringsSep "\n"
          (user: "iptables -w -A ${chain} -m owner --uid-owner ${user} -j RETURN")
          cfg'.localAccess.allowedUsers;
      in
      {
        # `-w` throughout: podman/netavark rewrites iptables whenever a
        # container starts, and an unlucky collision on the xtables lock would
        # otherwise fail firewall.service.
        extraCommands = ''
          # signal-api: restrict the unauthenticated REST API to approved local users
          iptables -w -N ${chain} 2>/dev/null || true
          iptables -w -F ${chain}
          ${allowRules}
          iptables -w -A ${chain} -j REJECT --reject-with tcp-reset
          iptables -w -C OUTPUT ${jumpMatch} 2>/dev/null || iptables -w -I OUTPUT 1 ${jumpMatch}
        '';

        extraStopCommands = ''
          iptables -w -D OUTPUT ${jumpMatch} 2>/dev/null || true
          iptables -w -F ${chain} 2>/dev/null || true
          iptables -w -X ${chain} 2>/dev/null || true
        '';
      }
    );
  };
}
