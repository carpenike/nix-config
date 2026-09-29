# shellcheck shell=bash
set -euo pipefail

metrics_file="$1"
pending="${metrics_file}.pending"
lint="${pending}.lint"
trap 'rm -f -- "$pending" "$lint"' EXIT

status=0
homelab-finances-ingest metrics > "$pending" || status=$?

# Read failures deliberately return nonzero WITH valid failure metrics. Publish
# those, but never replace evidence with an empty traceback or malformed output.
grep -Eq '^finance_ingest_state_read_success [01](\.0+)?$' "$pending"
grep -Eq '^finance_ingest_metrics_generated_timestamp_seconds [0-9]+(\.[0-9]+)?$' "$pending"
lint_status=0
promtool check metrics < "$pending" > "$lint" 2>&1 || lint_status=$?
# Exit 3 is lint (for example optional HELP text), not an exposition parse error.
case "$lint_status" in
  0|3) ;;
  *) cat "$lint" >&2; exit "$lint_status" ;;
esac
chmod 0640 "$pending"
mv -Tf -- "$pending" "$metrics_file"
exit "$status"
