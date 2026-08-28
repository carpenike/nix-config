# Grafana Alloy — browser telemetry (RUM) collector.
#
# Stage 1 of front-end observability for Operation W.W.W.: the app's SPA runs
# the Grafana Faro Web SDK (see upstream `src/telemetry/faro.ts`) and beacons
# Web Vitals, JS exceptions, page views, sessions and resource timings here.
# Alloy normalizes them and pushes them into the SAME Loki that already holds
# forge's journald logs via Promtail, so a browser error and the Fastify
# request behind it are one Explore query apart.
#
# This runs ALONGSIDE Promtail, it does not replace it. Promtail keeps
# shipping the journal; Alloy only owns the Faro receiver. Nothing here is
# stateful — no ZFS dataset, no backup job — the process holds at most a few
# seconds of in-flight beacons.
#
# Traffic path:
#   guest browser
#     └─► https://whiskeywhiskeywhiskey.org/relay/collect   (Cloudflare Tunnel)
#         └─► Caddy `handle_path /relay/*`  (strips the prefix)
#             └─► 127.0.0.1:12347/collect   (faro.receiver, this file)
#                 └─► 127.0.0.1:3100        (Loki)
#
# The `/relay` prefix is defined on the app's own vhost in
# `hosts/forge/services/whiskeywhiskeywhiskey.nix`. Same-origin on purpose:
# no CORS preflight, no second Cloudflare hostname, and a path that content
# blockers don't recognize as an analytics endpoint.
#
# NOTE: /relay/collect is UNAUTHENTICATED by necessity — it is called by
# anonymous guest browsers on the token-gated share pages. faro.receiver's
# api_key option wouldn't change that (the key would ship in the JS bundle).
# The controls that matter are the rate limit and payload cap below.

{ config, lib, pkgs, ... }:

let
  forgeDefaults = import ../../lib/defaults.nix { inherit config lib; };

  apexDomain = "whiskeywhiskeywhiskey.org";

  # Alloy's own HTTP surface: UI at /, its Prometheus metrics at /metrics.
  # Loopback only — Prometheus scrapes it from this host.
  alloyListenAddress = "127.0.0.1";
  alloyListenPort = 12345;

  # faro.receiver's HTTP server. Loopback only; Caddy is the only caller.
  faroListenAddress = "127.0.0.1";
  faroListenPort = 12347;

  lokiPushUrl = "http://127.0.0.1:3100/loki/api/v1/push";

  # Grafana's dashboard provider needs a path that EXISTS ON FORGE AT RUNTIME.
  #
  # `path = ./dashboards` does not: inside a flake it resolves to a subpath of
  # the evaluated flake source (/nix/store/<hash>-source/hosts/...), which is a
  # build-time input, not part of the system closure. It survived `nix eval`
  # and the deploy, then Grafana logged "failed to walk provisioned dashboards
  # ... no such file or directory" every 60s and the dashboard never appeared.
  #
  # Copying the JSON into a derivation of its own gives the provisioner a real
  # store path that the closure references and the deploy therefore copies.
  # (Same shape as the teslamate module, which points at a fetched source
  # derivation rather than at repo-relative paths.)
  dashboardsDir = pkgs.runCommandLocal "whiskey-faro-dashboards" { } ''
    mkdir -p "$out"
    cp ${./dashboards}/*.json "$out"/
  '';

  faroConfig = ''
    // Browser telemetry from the Operation W.W.W. SPA.
    //
    // `extra_log_labels` values that are the EMPTY STRING are promoted from
    // the beacon payload rather than set statically -- `kind` becomes one of
    // log | exception | measurement | event | span, which is what makes
    // {job="faro", kind="exception"} a usable Loki query. Everything else is
    // pinned here so a forged beacon can't invent its own label values (and
    // can't blow up Loki's stream cardinality).
    faro.receiver "www" {
      extra_log_labels = {
        kind        = "",
        job         = "faro",
        app         = "whiskey-whiskey-whiskey",
        host        = "forge",
        environment = "homelab",
      }

      // JSON lines parse cleanly in Grafana with `| json`; the upstream
      // default is logfmt, which mangles stack traces.
      log_format = "json"

      server {
        listen_address = "${faroListenAddress}"
        listen_port    = ${toString faroListenPort}

        // Redundant while Caddy proxies this on the app's own origin (a
        // same-origin POST sends no preflight), but correct if the collector
        // is ever moved to its own hostname.
        cors_allowed_origins = ["https://${apexDomain}"]

        // Upstream defaults are 5MiB / 50 rps / burst 100 -- sized for a
        // commercial front end. This is a household app whose busiest moment
        // is a dozen guests opening the Briefing Hub at once. Tighten both:
        // the endpoint is reachable from the public internet and the only
        // real failure mode is someone filling Loki with junk.
        max_allowed_payload_size = "512KiB"

        rate_limiting {
          enabled    = true
          strategy   = "global"
          rate       = 10
          burst_size = 20
        }
      }

      // Stack traces stay minified. Vite emits no sourcemaps for the
      // production build, and turning them on would publish the client
      // source on the unauthenticated share pages. Left explicitly false
      // because upstream defaults to download = true with
      // download_from_origins = ["*"], which is an outbound-fetch surface
      // driven by attacker-controllable stack frame URLs.
      sourcemaps {
        download = false
      }

      // No `traces` output: tracing is Stage 2 and needs a Tempo to point at.
      output {
        logs = [loki.write.faro.receiver]
      }
    }

    loki.write "faro" {
      endpoint {
        url = "${lokiPushUrl}"
      }
    }
  '';
in
{
  config = {
    services.alloy = {
      enable = true;
      extraFlags = [
        "--server.http.listen-addr=${alloyListenAddress}:${toString alloyListenPort}"
        # No usage telemetry back to Grafana Labs.
        "--disable-reporting"
      ];
    };

    # The nixpkgs module reads every *.alloy file under /etc/alloy and wires
    # them into the unit's reloadTriggers, so editing this re-loads Alloy on
    # `nixos-rebuild switch` rather than restarting it.
    environment.etc."alloy/www-faro.alloy".text = faroConfig;

    # Alloy must not start before Loki is accepting pushes, or the first
    # beacons of a boot are dropped on the floor.
    systemd.services.alloy = {
      after = [ "loki.service" ];
      wants = [ "loki.service" ];
    };

    # Provisioned RUM dashboard. `dashboardsDir` wraps a DIRECTORY of dashboard
    # JSON, so further front-end dashboards drop into ./dashboards alongside
    # this one with no change here. Grafana rescans every 60s; the files stay
    # editable in the UI but edits are overwritten on the next rebuild -- the
    # JSON in this repo is the source of truth.
    modules.services.grafana.provisioning.dashboards.whiskey-faro = {
      name = "Operation W.W.W.";
      folder = "Applications";
      path = dashboardsDir;
    };

    modules.alerting.rules."alloy-service-down" =
      forgeDefaults.mkSystemdServiceDownAlert
        "alloy"
        "Grafana Alloy"
        "browser telemetry (Faro) collector";
  };
}
