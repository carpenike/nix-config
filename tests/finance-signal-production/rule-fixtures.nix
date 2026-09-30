{ lib, rules }:
let
  labels = { instance = "forge.holthome.net"; job = "node"; };
  reportMetric = name: kind: ''finance_signal_${name}{kind="${kind}",'';
  workerState = ''node_systemd_unit_state{name="finance-signal-metrics.service",state="failed",'';
  reportWorkerState = ''node_systemd_unit_state{name="finance-signal-report@daily.service",state="failed",'';
  baseline = {
    finance_signal_check_timestamp_seconds = "0+60x60";
    finance_signal_path_healthy = "1x60";
    finance_signal_listener_healthy = "1x60";
    finance_signal_ack_attention = "0x60";
    ${workerState} = "0x60";
  } // lib.foldl'
    (acc: kind: acc // {
      ${reportMetric "report_status_available" kind} = "1x60";
      ${reportMetric "report_fulfilled" kind} = "1x60";
      ${reportMetric "report_attention" kind} = "0x60";
      ${reportMetric "report_deadline_timestamp_seconds" kind} = "945x60";
    })
    { } [ "daily" "weekly" ];
  expected = name: extra: [{
    exp_labels = rules.${name}.labels // { severity = "high"; } // extra;
    exp_annotations = rules.${name}.annotations;
  }];
  test = name: time: overrides: firing: {
    inherit name;
    interval = "1m";
    input_series = lib.mapAttrsToList
      (metric: values: {
        series = metric + lib.optionalString (!(lib.hasInfix "{" metric)) "{"
          + ''instance="forge.holthome.net",job="node"}'';
        inherit values;
      })
      (baseline // overrides);
    alert_rule_test = lib.mapAttrsToList
      (key: r: {
        inherit (r) alertname;
        eval_time = time;
        exp_alerts = firing.${key} or [ ];
      })
      rules;
  };
in
{
  rule_files = [ "rules.json" ];
  evaluation_interval = "15s";
  tests = [
    (test "fulfilled slots remain quiet" "25m" { } { })
    (test "before first cutover slots missing or old failures never page" "25m"
      (
        lib.foldl'
          (acc: kind: acc // {
            ${reportMetric "report_status_available" kind} = "0x60";
            ${reportMetric "report_fulfilled" kind} = "0x60";
            ${reportMetric "report_attention" kind} = "1x60";
            ${reportMetric "report_deadline_timestamp_seconds" kind} = "0x60";
          })
          { } [ "daily" "weekly" ]
      )
      { })
    (test "daily starts independently before first Friday slot" "25m"
      {
        ${reportMetric "report_status_available" "weekly"} = "0x60";
        ${reportMetric "report_fulfilled" "weekly"} = "0x60";
        ${reportMetric "report_deadline_timestamp_seconds" "weekly"} = "0x60";
      }
      { })
    (test "native cutoff does not page while the third attempt can be stopping" "15m"
      {
        ${reportMetric "report_fulfilled" "daily"} = "0x60";
        ${reportWorkerState} = "1x60";
      }
      { })
    (test "at the exact alarm deadline stop grace has not been exceeded" "15m45s"
      {
        ${reportMetric "report_fulfilled" "daily"} = "0x60";
        ${reportWorkerState} = "1x60";
      }
      { })
    (test "first preparation fails and second attempt fulfills the same purpose" "16m"
      {
        ${reportMetric "report_fulfilled" "daily"} = "0x5 1x54";
        ${reportWorkerState} = "1x5 0x54";
      }
      { })
    (test "failed preparations do not page before the third attempt finishes" "14m"
      {
        ${reportMetric "report_fulfilled" "daily"} = "0x60";
        ${reportWorkerState} = "1x60";
      }
      { })
    (test "missing daily is high immediately after the deadline" "16m"
      {
        ${reportMetric "report_fulfilled" "daily"} = "0x60";
        ${reportWorkerState} = "1x60";
      }
      {
        finance-signal-report-missed = expected "finance-signal-report-missed" (labels // { kind = "daily"; });
      })
    (test "old weekly failure does not satisfy the next slot" "16m"
      {
        ${reportMetric "report_fulfilled" "weekly"} = "0x60";
      }
      {
        finance-signal-report-missed = expected "finance-signal-report-missed" (labels // { kind = "weekly"; });
      })
    (test "current unknown outcome is high even before deadline" "3m"
      {
        ${reportMetric "report_fulfilled" "weekly"} = "0x60";
        ${reportMetric "report_attention" "weekly"} = "1x60";
      }
      {
        finance-signal-report-attention = expected "finance-signal-report-attention" (labels // { kind = "weekly"; });
      })
    (test "malformed or unreadable current status fails closed" "3m"
      {
        ${reportMetric "report_status_available" "daily"} = "0x60";
        ${reportMetric "report_fulfilled" "daily"} = "0x60";
        ${reportMetric "report_attention" "daily"} = "1x60";
      }
      {
        finance-signal-report-unavailable = expected "finance-signal-report-unavailable" (labels // { kind = "daily"; });
        finance-signal-report-attention = expected "finance-signal-report-attention" (labels // { kind = "daily"; });
      })
    (test "listener disconnected stale or destination changed is high" "3m"
      {
        finance_signal_listener_healthy = "0x60";
      }
      {
        finance-signal-listener-unhealthy = expected "finance-signal-listener-unhealthy" labels;
      })
    (test "failed unknown and overdue ACKs are high" "3m"
      {
        finance_signal_ack_attention = "1x60";
      }
      {
        finance-signal-ack-attention = expected "finance-signal-ack-attention" labels;
      })
    (test "path failure independent of live listener and recent observer" "3m"
      {
        finance_signal_path_healthy = "0x60";
      }
      {
        finance-signal-path-unhealthy = expected "finance-signal-path-unhealthy" labels;
      })
    (test "stale collector independent of good listener and report receipts" "8m"
      {
        finance_signal_check_timestamp_seconds = "0x60";
      }
      {
        finance-signal-monitor-stale = expected "finance-signal-monitor-stale" labels;
      })
    (test "missing metrics file is high" "3m"
      {
        finance_signal_check_timestamp_seconds = "_x60";
        finance_signal_path_healthy = "_x60";
        finance_signal_listener_healthy = "_x60";
      }
      {
        finance-signal-monitor-stale = expected "finance-signal-monitor-stale" { };
        finance-signal-path-unhealthy = expected "finance-signal-path-unhealthy" { };
        finance-signal-listener-unhealthy = expected "finance-signal-listener-unhealthy" { };
      })
    (test "publication failure pages before old metrics become stale" "3m"
      {
        ${workerState} = "1x60";
      }
      {
        finance-signal-unit-failed = expected "finance-signal-unit-failed" (labels // {
          name = "finance-signal-metrics.service";
          state = "failed";
        });
      })
    (test "future observer timestamp is not healthy" "3m"
      {
        finance_signal_check_timestamp_seconds = "3600x60";
      }
      {
        finance-signal-monitor-stale = expected "finance-signal-monitor-stale" labels;
      })
  ];
}
