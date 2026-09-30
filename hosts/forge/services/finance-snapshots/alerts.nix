{ worker, host }:
let
  rule = alertname: duration: expr: summary: description: {
    type = "promql";
    severity = "high";
    inherit alertname expr;
    for = duration;
    labels = {
      inherit host;
      service = "finance-snapshot";
      category = "finance";
    };
    annotations = { inherit summary description; };
  };
in
{
  finance-snapshot-unavailable =
    rule "FinanceSnapshotUnavailable" "2m"
      ''
        finance_snapshot_status_available == 0
        or absent(finance_snapshot_status_available)
      ''
      "Finance snapshot status is unavailable"
      "The exporter could not verify its private source/configuration or PostgreSQL status, or emitted invalid evidence. Check ${worker}; never infer success from a no-op or a recent check.";

  finance-snapshot-export-failed =
    rule "FinanceSnapshotExportFailed" "2m"
      ''
        finance_snapshot_export_failed == 1
      ''
      "Finance snapshot export failure remains unresolved"
      "The last recorded export failed, or the wrapper could not obtain valid evidence. Waiting/already-current polls do not clear this incident. Inspect private exporter evidence; do not replay a bank POST.";

  finance-snapshot-worker-failed =
    rule "FinanceSnapshotWorkerFailed" "30s"
      ''
        node_systemd_unit_state{name="${worker}.service",state="failed"} == 1
      ''
      "Finance snapshot check or metrics publication failed"
      "Inspect ${worker} mount assertions, environment-file access, deadline and aggregate metrics directory. Raw CLI output is deliberately not journaled; unchanged metrics are not recovery.";

  finance-snapshot-check-stale =
    rule "FinanceSnapshotCheckStale" "2m"
      ''
        time() - finance_snapshot_check_timestamp_seconds > 900
        or finance_snapshot_check_timestamp_seconds > time() + 60
        or absent(finance_snapshot_check_timestamp_seconds)
      ''
      "Finance snapshot monitoring is absent, stale or future-dated"
      "No valid observer check for over 15 minutes, or its clock is ahead. Inspect ${worker}.timer, its service and the node-exporter textfile link. Check time is not snapshot or bank freshness.";

  finance-snapshot-timer-stopped =
    rule "FinanceSnapshotTimerStopped" "5m"
      ''
        node_systemd_unit_state{name="${worker}.timer",state="active"} == 0
        or absent(node_systemd_unit_state{name="${worker}.timer",state="active"})
      ''
      "Finance snapshot polling timer is stopped or missing"
      "Check ${worker}.timer. This five-minute poll is GET-only apart from the existing projection writer; do not substitute bank sync, an OnSuccess hook or a new notifier.";

  finance-snapshot-ingestion-unpublished =
    rule "FinanceSnapshotIngestionUnpublished" "2m"
      ''
        finance_ingest_last_reported_timestamp_seconds
          > on (instance, job) finance_snapshot_checkpoint_ingestion_finished_timestamp_seconds
        and on (instance, job) (time() - finance_ingest_last_reported_timestamp_seconds > 900)
        and on (instance, job) (finance_ingest_in_flight == 0)
        and on (instance, job) (finance_ingest_state_read_success == 1)
      ''
      "A completed finance ingestion has no matching snapshot after 15 minutes"
      "Compare the durable ingestion report with the export checkpoint. A fresh check or an unrelated nightly export does not satisfy this watermark. Waiting during a live bank pull is normal; recorded export failures remain actionable.";
}
