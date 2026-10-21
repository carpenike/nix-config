# Weekly warwed.com funnel report for Operation W.W.W.
#
#   event page -> competition page -> registration page -> registration POST
#   -> competition_entries -> Partiful RSVP snapshot (week-over-week diff)
#
# Read-only against its inputs: Loki's HTTP API on loopback and the app's
# SQLite DB opened with `mode=ro`. The only writes are the report files under
# the service's state dir (`${dataDir}/funnel-report`, on the
# tank/services/whiskeywhiskeywhiskey dataset, so restic/syncoid cover it)
# and a node_exporter textfile metric.
#
# Delivery is deliberately NOT wired up yet (email / Slack / Grafana is an
# open decision). Read the latest report with:
#   sudo cat /var/lib/whiskey-whiskey-whiskey/funnel-report/latest.md
# or run it on demand:
#   sudo systemctl start whiskey-funnel-report && journalctl -u whiskey-funnel-report -n 80
{ config, lib, pkgs, ... }:
let
  # Same path the main service uses (hosts/forge/services/whiskeywhiskeywhiskey.nix).
  dataDir = "/var/lib/whiskey-whiskey-whiskey";
  # The DynamicUser StateDirectory lives under /var/lib/private; the
  # /var/lib/<name> path is systemd's symlink to it.
  privateDataDir = "/var/lib/private/whiskey-whiskey-whiskey";
  reportDir = "${privateDataDir}/funnel-report";
  metricsDir = "/var/lib/node_exporter/textfile_collector";
  lokiPort = 3100;

  serviceEnabled = config.services.whiskey-whiskey-whiskey.enable or false;

  funnelReport = pkgs.writers.writePython3Bin "whiskey-funnel-report"
    {
      # Generated report formatting; not worth line-length churn.
      flakeIgnore = [ "E501" "E731" "W503" ];
    }
    (builtins.readFile ./report.py);
in
{
  config = lib.mkIf serviceEnabled {
    systemd.services.whiskey-funnel-report = {
      description = "Weekly warwed.com funnel report (Loki + read-only SQLite)";
      after = [ "loki.service" ];
      wants = [ "loki.service" ];
      unitConfig.RequiresMountsFor = [ dataDir ];
      environment.TZ =
        if config.time.timeZone != null then config.time.timeZone else "America/New_York";
      serviceConfig = {
        Type = "oneshot";
        # Root: the DB sits in the DynamicUser's 0700 StateDirectory. The
        # script opens it `mode=ro`; ReadWritePaths covers only the report
        # dir, SQLite's -shm (WAL readers need it) and the metrics dir.
        ExecStart = lib.concatStringsSep " " [
          "${funnelReport}/bin/whiskey-funnel-report"
          "--loki http://127.0.0.1:${toString lokiPort}"
          "--db ${privateDataDir}/db.sqlite"
          "--state-dir ${reportDir}"
          "--metrics-file ${metricsDir}/whiskey_funnel.prom"
          "--host warwed.com"
          "--days 7"
        ];
        ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0750 ${reportDir}";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        ReadWritePaths = [ privateDataDir metricsDir ];
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
  };
}
