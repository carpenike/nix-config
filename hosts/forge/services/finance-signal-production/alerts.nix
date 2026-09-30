{ host }:
let
  rule = alertname: duration: expr: summary: description: {
    type = "promql";
    severity = "high";
    inherit alertname expr;
    for = duration;
    labels = { inherit host; service = "finance-signal"; category = "finance"; };
    annotations = { inherit summary description; };
  };
in
{
  finance-signal-path-unhealthy = rule "FinanceSignalPathUnhealthy" "2m"
    ''finance_signal_path_healthy == 0 or absent(finance_signal_path_healthy)''
    "Canonical finance context storage is unavailable or unsafe"
    "Check the MCP dataset mount, ownership, 0700 parent and exact 0600 DB/journal/lease modes. Never create a replacement DB or recursively chmod state.";

  finance-signal-listener-unhealthy = rule "FinanceSignalListenerUnhealthy" "2m"
    ''finance_signal_listener_healthy == 0 or absent(finance_signal_listener_healthy)''
    "Finance Signal capture is disconnected, stale or unverifiable"
    "Inspect native listener status and the single receive owner. Check loopback/DNAT and UID access. No noted acknowledgment means the sender must resend; do not invent receipt or recovery.";

  finance-signal-ack-attention = rule "FinanceSignalAckAttention" "1m"
    ''finance_signal_ack_attention == 1''
    "Finance capture has failed, unknown or overdue acknowledgments"
    "Use native read-only status to inspect durable ACK evidence. A committed note is not a delivered ACK; never reset a reservation or automatically retry an ambiguous POST.";

  finance-signal-report-unavailable = rule "FinanceSignalReportUnavailable" "2m"
    ''
      finance_signal_report_status_available == 0
        and on (instance, job, kind) (finance_signal_report_deadline_timestamp_seconds > 0)
    ''
    "Current finance report status cannot be verified"
    "The current post-cutover slot cannot be read with current Family/Ops destination fingerprints. Do not infer fulfillment from old receipts or service success.";

  finance-signal-report-attention = rule "FinanceSignalReportAttention" "1m"
    ''
      finance_signal_report_attention == 1
        and on (instance, job, kind) (finance_signal_report_deadline_timestamp_seconds > 0)
    ''
    "Current finance report has a non-retryable failure or unknown outcome"
    "Inspect metadata-only native report status. Retryable preparation failures use the completion deadline; failed/unknown/reserved sends remain immediately actionable and must never be blindly retried.";

  finance-signal-report-missed = rule "FinanceSignalReportMissed" "0m"
    ''
      (finance_signal_report_fulfilled == 0)
        and on (instance, job, kind) (finance_signal_report_deadline_timestamp_seconds > 0)
        and on (instance, job, kind) (finance_signal_report_deadline_timestamp_seconds < time())
    ''
    "Finance report purpose missed its completion deadline"
    "The current eligible slot remains unfulfilled after its native fifteen-minute window plus 45 seconds of unit stop grace. Pre-cutover slots are excluded. Diagnose locally; the grace never authorizes a late POST or catch-up.";

  finance-signal-monitor-stale = rule "FinanceSignalMonitorStale" "2m"
    ''
      time() - finance_signal_check_timestamp_seconds > 300
      or finance_signal_check_timestamp_seconds > time() + 60
      or absent(finance_signal_check_timestamp_seconds)
    ''
    "Finance Signal monitoring is missing, stale or future-dated"
    "Check finance-signal-metrics.timer, its service, private setgid directory and node-exporter link independently of the listener/CLI. This is not an off-host dead-man.";

  finance-signal-unit-failed = rule "FinanceSignalUnitFailed" "1m"
    ''
      node_systemd_unit_state{name=~"finance-signal-(capture|metrics)\\.service",state="failed"} == 1
    ''
    "Finance Signal capture or monitoring failed"
    "Inspect fixed error codes, start limits, mount gates and metrics publication. Report units use native outcome/deadline alerts so a retryable preparation does not page between bounded attempts. Preserve canonical state and reservations.";
}
