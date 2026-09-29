{ lib, rules }:
let
  scrapeLabels = {
    instance = "forge.holthome.net";
    job = "node";
  };
  workerState = ''node_systemd_unit_state{name="homelab-mcp-finances-ingest.service",state="failed",'';
  timerState = ''node_systemd_unit_state{name="homelab-mcp-finances-ingest.timer",state="active",'';
  collectorState = ''node_systemd_unit_state{name="finance-ingest-metrics.service",state="failed",'';
  baseline = {
    finance_ingest_state_read_success = "1x100";
    finance_ingest_metrics_generated_timestamp_seconds = "0+60x100";
    finance_ingest_last_attempt_timestamp_seconds = "1x100";
    finance_ingest_last_finished_timestamp_seconds = "2x100";
    finance_ingest_last_reported_timestamp_seconds = "2x100";
    finance_ingest_next_attempt_timestamp_seconds = "86401x100";
    finance_ingest_post_outcome_unknown = "0x100";
    finance_ingest_in_flight = "0x100";
    finance_ingest_last_run_failed = "0x100";
    finance_ingest_accounts_expected = "22x100";
    finance_ingest_accounts_verified = "22x100";
    finance_ingest_accounts_needing_attention = "0x100";
    finance_ingest_accounts_other_failures = "0x100";
    ${workerState} = "0x100";
    ${timerState} = "1x100";
    ${collectorState} = "0x100";
  };
  expected = key: severity: labels: [
    {
      exp_labels = rules.${key}.labels // { inherit severity; } // labels;
      exp_annotations = rules.${key}.annotations;
    }
  ];
  test = name: evalTime: overrides: firing: {
    inherit name;
    interval = "1m";
    input_series = lib.mapAttrsToList
      (metric: values: {
        series =
          metric
          + lib.optionalString (!(lib.hasInfix "{" metric)) "{"
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
    (test "healthy state is quiet between eligible attempts" "12m" { } { })
    (test "21 verified and one attention is LOW, never a pipeline outage" "12m"
      {
        finance_ingest_accounts_verified = "21x100";
        finance_ingest_accounts_needing_attention = "1x100";
      }
      {
        finance-ingest-bank-attention = expected "finance-ingest-bank-attention" "low" scrapeLabels;
      }
    )
    (test "every bank needs attention is a HIGH pipeline failure" "12m"
      {
        finance_ingest_accounts_verified = "0x100";
        finance_ingest_accounts_needing_attention = "22x100";
      }
      {
        finance-ingest-pipeline-failed = expected "finance-ingest-pipeline-failed" "high" scrapeLabels;
      }
    )
    (test "verification failure is HIGH even with most accounts verified" "12m"
      {
        finance_ingest_accounts_verified = "21x100";
        finance_ingest_accounts_other_failures = "1x100";
      }
      {
        finance-ingest-pipeline-failed = expected "finance-ingest-pipeline-failed" "high" scrapeLabels;
      }
    )
    (test "failed run does not inherit an old healthy report" "12m"
      {
        finance_ingest_last_run_failed = "1x100";
      }
      {
        finance-ingest-pipeline-failed = expected "finance-ingest-pipeline-failed" "high" scrapeLabels;
      }
    )
    (test "incomplete latest partial cannot reuse an older complete report" "12m"
      {
        finance_ingest_accounts_verified = "21x100";
        finance_ingest_accounts_needing_attention = "1x100";
        finance_ingest_last_finished_timestamp_seconds = "600x100";
      }
      {
        finance-ingest-pipeline-failed = expected "finance-ingest-pipeline-failed" "high" scrapeLabels;
      }
    )
    (test "unknown completed outcome requires operator recovery" "12m"
      {
        finance_ingest_post_outcome_unknown = "1x100";
      }
      {
        finance-ingest-outcome-unknown = expected "finance-ingest-outcome-unknown" "high" scrapeLabels;
      }
    )
    (test "legitimate in-flight reservation has deadline grace, even after eligibility" "36m"
      {
        finance_ingest_post_outcome_unknown = "1x100";
        finance_ingest_in_flight = "1x100";
        finance_ingest_last_attempt_timestamp_seconds = "2100x100";
        finance_ingest_next_attempt_timestamp_seconds = "1x100";
      }
      { })
    (test "a retry is not recovery from the previous completed failure" "36m"
      {
        finance_ingest_post_outcome_unknown = "1x100";
        finance_ingest_in_flight = "1x100";
        finance_ingest_last_attempt_timestamp_seconds = "2100x100";
        finance_ingest_last_run_failed = "1x100";
      }
      {
        finance-ingest-pipeline-failed = expected "finance-ingest-pipeline-failed" "high" scrapeLabels;
      }
    )
    (test "bank attention stays LOW through a running retry instead of re-paging" "36m"
      {
        finance_ingest_post_outcome_unknown = "1x100";
        finance_ingest_in_flight = "1x100";
        finance_ingest_last_attempt_timestamp_seconds = "2100x100";
        finance_ingest_accounts_verified = "21x100";
        finance_ingest_accounts_needing_attention = "1x100";
      }
      {
        finance-ingest-bank-attention = expected "finance-ingest-bank-attention" "low" scrapeLabels;
      }
    )
    (test "failed preflight retries cannot transiently resolve an overdue incident" "36m"
      {
        finance_ingest_in_flight = "1x100";
        finance_ingest_last_attempt_timestamp_seconds = "2100x100";
        finance_ingest_last_run_failed = "1x100";
        finance_ingest_next_attempt_timestamp_seconds = "1x100";
      }
      {
        finance-ingest-pipeline-failed = expected "finance-ingest-pipeline-failed" "high" scrapeLabels;
        finance-ingest-overdue = expected "finance-ingest-overdue" "high" scrapeLabels;
      }
    )
    (test "stalled in-flight reservation cannot mask an unknown POST forever" "14m"
      {
        finance_ingest_post_outcome_unknown = "1x100";
        finance_ingest_in_flight = "1x100";
      }
      {
        finance-ingest-outcome-unknown = expected "finance-ingest-outcome-unknown" "high" scrapeLabels;
      }
    )
    (test "eligibility plus thirty-minute grace must not be missed" "34m"
      {
        finance_ingest_next_attempt_timestamp_seconds = "1x100";
      }
      {
        finance-ingest-overdue = expected "finance-ingest-overdue" "high" scrapeLabels;
      }
    )
    (test "a stopped timer is HIGH independently of healthy last-run data" "12m"
      {
        ${timerState} = "0x100";
      }
      {
        finance-ingest-timer-stopped = expected "finance-ingest-timer-stopped" "high" (
          scrapeLabels
          // {
            name = "homelab-mcp-finances-ingest.timer";
            state = "active";
          }
        );
      }
    )
    (test "a missing timer is also HIGH" "12m"
      {
        ${timerState} = "_x100";
      }
      {
        finance-ingest-timer-stopped = expected "finance-ingest-timer-stopped" "high" {
          name = "homelab-mcp-finances-ingest.timer";
          state = "active";
        };
      }
    )
    (test "refused or failed worker startup is HIGH" "12m"
      {
        ${workerState} = "1x100";
      }
      {
        finance-ingest-worker-failed = expected "finance-ingest-worker-failed" "high" (
          scrapeLabels
          // {
            name = "homelab-mcp-finances-ingest.service";
            state = "failed";
          }
        );
      }
    )
    (test "valid state-read-failure metrics remain actionable" "12m"
      {
        finance_ingest_state_read_success = "0x100";
      }
      {
        finance-ingest-collector-failed = expected "finance-ingest-collector-failed" "high" scrapeLabels;
      }
    )
    (test "publication failure is HIGH before previous metrics become stale" "2m"
      {
        ${collectorState} = "1x100";
        finance_ingest_metrics_generated_timestamp_seconds = "0x100";
      }
      {
        finance-ingest-collector-failed = expected "finance-ingest-collector-failed" "high" scrapeLabels;
      }
    )
    (test "an old file cannot keep collection green" "12m"
      {
        finance_ingest_metrics_generated_timestamp_seconds = "0x100";
      }
      {
        finance-ingest-collector-stale = expected "finance-ingest-collector-stale" "high" scrapeLabels;
      }
    )
    (test "missing metrics detect an unstarted collector" "12m"
      {
        finance_ingest_metrics_generated_timestamp_seconds = "_x100";
        finance_ingest_state_read_success = "_x100";
      }
      {
        finance-ingest-collector-stale = expected "finance-ingest-collector-stale" "high" { };
      }
    )
  ];
}
