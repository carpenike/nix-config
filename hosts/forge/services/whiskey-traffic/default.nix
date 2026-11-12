# warwed.com (Operation W.W.W. public site) traffic reporting on Forge.
#
#   * Grafana dashboard "W.W.W. — warwed.com traffic", rendered at runtime
#     from ./whiskey-warwed-traffic.json so its `exclude_ips` default can
#     carry the household's public IP without committing it (this repo is
#     public).
#   * whiskey-traffic-exclusions: refreshes that IP from Forge's own egress
#     (Cloudflare /cdn-cgi/trace on 1.1.1.1), merges an optional hand-kept
#     list, writes the exclusion regex and re-renders the dashboard.
#   * whiskey-funnel-report: weekly funnel (event page -> competition ->
#     register -> entries -> Partiful RSVP snapshot with week-over-week diff)
#     from Loki + a read-only open of the app's SQLite DB.
#
# Readable without sudo (0755 dirs, 0644 files; aggregate counts only):
#   /var/lib/whiskey-traffic/funnel-report/latest.json   (+ latest.md)
#   /var/lib/whiskey-traffic/funnel-report/funnel-YYYY-MM-DD.{json,md}
# Root-only (0600): exclude-ips.auto, exclude-ips.local, exclude-regex.
#
# Extra exclusions (e.g. a second home connection or a phone hotspot prefix):
#   sudo install -m 0600 /dev/null /var/lib/whiskey-traffic/exclude-ips.local   # once
#   sudoedit /var/lib/whiskey-traffic/exclude-ips.local   # one IP or prefix ("203.0.113." / "2001:db8:1:2:") per line
#   sudo systemctl start whiskey-traffic-exclusions
{ config, lib, pkgs, ... }:
let
  stateDir = "/var/lib/whiskey-traffic";
  reportDir = "${stateDir}/funnel-report";
  grafanaDir = "${stateDir}/grafana";
  # The app's DynamicUser StateDirectory (see whiskeywhiskeywhiskey.nix);
  # /var/lib/whiskey-whiskey-whiskey is systemd's symlink to it.
  appDataDir = "/var/lib/whiskey-whiskey-whiskey";
  appPrivateDir = "/var/lib/private/whiskey-whiskey-whiskey";
  metricsDir = "/var/lib/node_exporter/textfile_collector";
  lokiPort = 3100;

  serviceEnabled = config.services.whiskey-whiskey-whiskey.enable or false;
  grafanaEnabled = config.modules.services.grafana.enable or false;

  flakeIgnore = [ "E501" "E731" "W503" ];
  funnelReport = pkgs.writers.writePython3Bin "whiskey-funnel-report" { inherit flakeIgnore; }
    (builtins.readFile ./report.py);
  exclusions = pkgs.writers.writePython3Bin "whiskey-traffic-exclusions" { inherit flakeIgnore; }
    (builtins.readFile ./exclusions.py);

  hardening = {
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    UMask = "0022";
  };
in
{
  config = lib.mkIf serviceEnabled (lib.mkMerge [
    {
      modules.system.impermanence.directories = [{
        directory = stateDir;
        user = "root";
        group = "root";
        mode = "0755";
      }];

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0755 root root - -"
        "d ${reportDir} 0755 root root - -"
        "d ${grafanaDir} 0750 root ${if grafanaEnabled then "grafana" else "root"} - -"
      ];

      systemd.services.whiskey-traffic-exclusions = {
        description = "warwed.com traffic: refresh household IP exclusion and render dashboard";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = hardening // {
          Type = "oneshot";
          ExecStart = lib.concatStringsSep " " [
            "${exclusions}/bin/whiskey-traffic-exclusions"
            "--state-dir ${stateDir}"
            "--template ${./whiskey-warwed-traffic.json}"
            "--dashboard-out ${grafanaDir}/whiskey-warwed-traffic.json"
          ];
          ReadWritePaths = [ stateDir ];
          TimeoutStartSec = "2m";
        };
      };

      systemd.timers.whiskey-traffic-exclusions = {
        description = "Refresh warwed.com household IP exclusion";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m";
          OnUnitActiveSec = "6h";
          RandomizedDelaySec = "5m";
          Persistent = true;
        };
      };

      systemd.services.whiskey-funnel-report = {
        description = "Weekly warwed.com funnel report (Loki + read-only SQLite)";
        after = [ "loki.service" "whiskey-traffic-exclusions.service" ];
        wants = [ "loki.service" "whiskey-traffic-exclusions.service" ];
        unitConfig.RequiresMountsFor = [ appDataDir ];
        environment.TZ =
          if config.time.timeZone != null then config.time.timeZone else "America/New_York";
        serviceConfig = hardening // {
          Type = "oneshot";
          # Root: the DB sits in the DynamicUser's 0700 StateDirectory. The
          # script opens it `mode=ro`; the app dir is writable only because
          # SQLite WAL readers need the -shm file.
          ExecStart = lib.concatStringsSep " " [
            "${funnelReport}/bin/whiskey-funnel-report"
            "--loki http://127.0.0.1:${toString lokiPort}"
            "--db ${appPrivateDir}/db.sqlite"
            "--state-dir ${reportDir}"
            "--metrics-file ${metricsDir}/whiskey_funnel.prom"
            "--exclude-regex-file ${stateDir}/exclude-regex"
            "--host warwed.com"
            "--days 7"
          ];
          ReadWritePaths = [ stateDir appPrivateDir metricsDir ];
          TimeoutStartSec = "30m";
          Nice = 10;
        };
      };

      systemd.timers.whiskey-funnel-report = {
        description = "Weekly warwed.com funnel report";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # Monday morning, covering the previous 7 days.
          OnCalendar = "Mon *-*-* 07:00:00";
          RandomizedDelaySec = "10m";
          Persistent = true;
        };
      };
    }

    (lib.mkIf grafanaEnabled {
      # Runtime-rendered (not a Nix store path) so the household IP stays off
      # GitHub. Grafana rescans every 60s; the first render happens at boot /
      # on switch via whiskey-traffic-exclusions.
      modules.services.grafana.provisioning.dashboards.whiskey-warwed-traffic = {
        name = "Operation W.W.W. (warwed.com traffic)";
        folder = "Applications";
        path = grafanaDir;
      };
    })
  ]);
}
