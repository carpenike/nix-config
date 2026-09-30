{ lib, rules }:
let
  scrapeLabels = {
    instance = "forge.holthome.net";
    job = "node";
  };
  workerState = ''node_systemd_unit_state{name="homelab-mcp-finances-snapshot.service",state="failed",'';
  timerState = ''node_systemd_unit_state{name="homelab-mcp-finances-snapshot.timer",state="active",'';
  baseline = {
    finance_snapshot_status_available = "1x100";
    finance_snapshot_export_failed = "0x100";
    finance_snapshot_check_timestamp_seconds = "0+60x100";
    finance_snapshot_last_success_timestamp_seconds = "1x100";
    finance_snapshot_checkpoint_ingestion_finished_timestamp_seconds = "1x100";
    finance_snapshot_checkpoint_export_finished_timestamp_seconds = "1x100";
    finance_ingest_last_reported_timestamp_seconds = "1x100";
    finance_ingest_state_read_success = "1x100";
    finance_ingest_in_flight = "0x100";
    ${workerState} = "0x100";
    ${timerState} = "1x100";
  };
  expected = key: labels: [{
    exp_labels = rules.${key}.labels // { severity = "high"; } // labels;
    exp_annotations = rules.${key}.annotations;
  }];
  test = name: evalTime: overrides: firing: {
    inherit name;
    interval = "1m";
    input_series = lib.mapAttrsToList
      (metric: values: {
        series = metric + lib.optionalString (!(lib.hasInfix "{" metric)) "{"
          + ''instance="forge.holthome.net",job="node",host="forge"}'';
        inherit values;
      })
      (baseline // overrides);
    alert_rule_test = lib.mapAttrsToList
      (key: r: {
        inherit (r) alertname;
        eval_time = evalTime;
        exp_alerts = firing.${key} or [ ];
      })
      rules;
  };
in
{
  rule_files = [ "rules.json" ];
  evaluation_interval = "1m";
  tests = [
    (test "published and already-current checkpoints remain quiet" "25m" { } { })
    (test "a published known partial is not an export failure" "25m"
      {
        finance_ingest_accounts_verified = "21x100";
        finance_ingest_accounts_needing_attention = "1x100";
      }
      { })
    (test "waiting on a live bank run is normal" "25m"
      {
        finance_ingest_in_flight = "1x100";
        finance_ingest_last_reported_timestamp_seconds = "2x100";
      }
      { })
    (test "waiting before the first completed report needs no snapshot" "25m"
      {
        finance_ingest_in_flight = "1x100";
        finance_ingest_last_reported_timestamp_seconds = "0x100";
        finance_snapshot_checkpoint_ingestion_finished_timestamp_seconds = "0x100";
      }
      { })
    (test "a recent completed report has fifteen minutes of publication grace" "15m"
      { finance_ingest_last_reported_timestamp_seconds = "2x100"; }
      { })
    (test "recent checks and unrelated nightly success cannot hide an unpublished run" "19m"
      {
        finance_ingest_last_reported_timestamp_seconds = "2x100";
        finance_snapshot_last_success_timestamp_seconds = "0+60x100";
        finance_snapshot_checkpoint_export_finished_timestamp_seconds = "0+60x100";
      }
      {
        finance-snapshot-ingestion-unpublished = expected "finance-snapshot-ingestion-unpublished" scrapeLabels;
      })
    (test "a missing first checkpoint is unpublished after grace" "19m"
      { finance_snapshot_checkpoint_ingestion_finished_timestamp_seconds = "0x100"; }
      {
        finance-snapshot-ingestion-unpublished = expected "finance-snapshot-ingestion-unpublished" scrapeLabels;
      })
    (test "an advancing matching checkpoint resolves publication lag" "25m"
      {
        finance_ingest_last_reported_timestamp_seconds = "2x100";
        finance_snapshot_checkpoint_ingestion_finished_timestamp_seconds = "1x19 2x80";
      }
      { })
    (test "exit-zero no-op does not clear the last recorded export failure" "25m"
      { finance_snapshot_export_failed = "1x100"; }
      {
        finance-snapshot-export-failed = expected "finance-snapshot-export-failed" scrapeLabels;
      })
    (test "waiting on a bank run does not hide existing export failure" "25m"
      {
        finance_snapshot_export_failed = "1x100";
        finance_ingest_in_flight = "1x100";
      }
      {
        finance-snapshot-export-failed = expected "finance-snapshot-export-failed" scrapeLabels;
      })
    (test "new successful evidence resolves the recorded failure" "25m"
      { finance_snapshot_export_failed = "1x19 0x80"; }
      { })
    (test "source database or wrapper failure is unavailable even with fresh checks" "5m"
      {
        finance_snapshot_status_available = "0x100";
        finance_snapshot_export_failed = "1x100";
      }
      {
        finance-snapshot-unavailable = expected "finance-snapshot-unavailable" scrapeLabels;
        finance-snapshot-export-failed = expected "finance-snapshot-export-failed" scrapeLabels;
      })
    (test "publication or startup failure is detected before old metrics age out" "2m"
      { ${workerState} = "1x100"; }
      {
        finance-snapshot-worker-failed = expected "finance-snapshot-worker-failed" (scrapeLabels // {
          name = "homelab-mcp-finances-snapshot.service";
          state = "failed";
        });
      })
    (test "stale check file is HIGH independently of snapshot freshness" "19m"
      { finance_snapshot_check_timestamp_seconds = "0x100"; }
      { finance-snapshot-check-stale = expected "finance-snapshot-check-stale" scrapeLabels; })
    (test "future-dated check file is not healthy monitoring" "5m"
      { finance_snapshot_check_timestamp_seconds = "3600x100"; }
      { finance-snapshot-check-stale = expected "finance-snapshot-check-stale" scrapeLabels; })
    (test "missing monitoring file is HIGH" "5m"
      {
        finance_snapshot_check_timestamp_seconds = "_x100";
        finance_snapshot_status_available = "_x100";
      }
      {
        finance-snapshot-check-stale = expected "finance-snapshot-check-stale" { };
        finance-snapshot-unavailable = expected "finance-snapshot-unavailable" { };
      })
    (test "stopped timer is HIGH with otherwise healthy evidence" "10m"
      { ${timerState} = "0x100"; }
      {
        finance-snapshot-timer-stopped = expected "finance-snapshot-timer-stopped" (scrapeLabels // {
          name = "homelab-mcp-finances-snapshot.timer";
          state = "active";
        });
      })
    (test "missing timer is also HIGH" "10m"
      { ${timerState} = "_x100"; }
      {
        finance-snapshot-timer-stopped = expected "finance-snapshot-timer-stopped" {
          name = "homelab-mcp-finances-snapshot.timer";
          state = "active";
        };
      })
  ];
}
