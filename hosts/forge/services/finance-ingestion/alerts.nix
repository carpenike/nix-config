{ worker
, collector
, host
, runGraceSeconds
,
}:
let
  rule = alertname: severity: duration: expr: summary: description: {
    type = "promql";
    inherit alertname severity expr;
    for = duration;
    labels = {
      inherit host;
      service = "finance-ingestion";
      category = "finance";
    };
    annotations = { inherit summary description; };
  };
in
{
  # These gauges describe completed runs. A retry is not recovery: keep the
  # existing incident active until new completed evidence replaces it.
  finance-ingest-pipeline-failed =
    rule "FinanceIngestPipelineFailed" "high" "2m"
      ''
        (
          finance_ingest_last_run_failed == 1
          or finance_ingest_accounts_other_failures > 0
          or (finance_ingest_accounts_expected > 0 and finance_ingest_accounts_verified == 0)
          or finance_ingest_last_finished_timestamp_seconds > finance_ingest_last_reported_timestamp_seconds
        )
        and (finance_ingest_post_outcome_unknown == 0 or finance_ingest_in_flight == 1)
        and finance_ingest_state_read_success == 1
      ''
      "Finance ingestion failed required work"
      "The latest report is incomplete, the run failed, no expected accounts verified, or verification failed beyond bank attention. Inspect the durable report; do not retry inside the reservation.";

  finance-ingest-bank-attention =
    rule "FinanceIngestBankAttention" "low" "5m"
      ''
        finance_ingest_accounts_needing_attention > 0
        and finance_ingest_accounts_verified > 0
        and finance_ingest_accounts_other_failures == 0
        and finance_ingest_last_run_failed == 0
        and (finance_ingest_post_outcome_unknown == 0 or finance_ingest_in_flight == 1)
        and finance_ingest_last_reported_timestamp_seconds >= finance_ingest_last_finished_timestamp_seconds
        and finance_ingest_state_read_success == 1
      ''
      "Finance ingestion completed partially; bank attention is required"
      "Other accounts verified. Inspect the private report and the bank connection in SimpleFin Bridge. This is not a whole-pipeline outage; no automatic retry is authorized.";

  finance-ingest-outcome-unknown =
    rule "FinanceIngestOutcomeUnknown" "high" "2m"
      ''
        (finance_ingest_post_outcome_unknown == 1 and finance_ingest_in_flight == 0)
        or (
          finance_ingest_in_flight == 1
          and time() - finance_ingest_last_attempt_timestamp_seconds > ${toString runGraceSeconds}
        )
      ''
      "Finance ingestion has an unknown outcome or a stalled run"
      "A normal bounded run is given its deadline plus two minutes. Preserve state and inspect the sidecar and ledger before explicit recovery; never clear quota state or replay an ambiguous POST.";

  finance-ingest-overdue =
    rule "FinanceIngestOverdue" "high" "2m"
      ''
        time() - finance_ingest_next_attempt_timestamp_seconds > 1800
        and (finance_ingest_in_flight == 0 or finance_ingest_last_run_failed == 1)
        and finance_ingest_state_read_success == 1
      ''
      "Finance ingestion is over 30 minutes past its next eligible attempt"
      "Inspect the eligibility timer and durable report. Eligibility polls are not bank pulls, and a fresh dashboard export is not evidence of ingestion.";

  finance-ingest-worker-failed =
    rule "FinanceIngestWorkerFailed" "high" "2m"
      ''
        node_systemd_unit_state{name="${worker}.service",state="failed"} == 1
      ''
      "Finance ingestion was refused or could not run"
      "Check credentials, mount assertions, ExecCondition and journalctl -u ${worker}. Only reported degraded exit 3 is accepted; failed exit 1 and refusal exit 2 remain failures.";

  finance-ingest-timer-stopped =
    rule "FinanceIngestTimerStopped" "high" "5m"
      ''
        node_systemd_unit_state{name="${worker}.timer",state="active"} == 0
        or absent(node_systemd_unit_state{name="${worker}.timer",state="active"})
      ''
      "Finance ingestion eligibility timer is stopped or missing"
      "Check systemctl status ${worker}.timer. Starting the timer must preserve the existing durable reservation; do not substitute another bank-sync owner.";

  finance-ingest-collector-failed =
    rule "FinanceIngestCollectorFailed" "high" "30s"
      ''
        max by (instance, job) (
          (finance_ingest_state_read_success == bool 0)
          or (node_systemd_unit_state{name="${collector}.service",state="failed"} == 1)
        ) == 1
      ''
      "Finance ingestion state collection or atomic publication failed"
      "Check journalctl -u ${collector} and runtime-directory permissions. Valid read-failure metrics are retained even on nonzero CLI exit; publication failures also fail this unit.";

  finance-ingest-collector-stale =
    rule "FinanceIngestCollectorStale" "high" "2m"
      ''
        time() - finance_ingest_metrics_generated_timestamp_seconds > 360
        or absent(finance_ingest_metrics_generated_timestamp_seconds)
      ''
      "Finance ingestion monitoring is absent or stale"
      "The independent two-minute collector has not published for over six minutes. Check ${collector}.timer, its service, and the node-exporter textfile link; MCP/OAuth/model availability is irrelevant.";
}
