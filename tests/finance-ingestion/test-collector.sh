#!/usr/bin/env bash
set -euo pipefail

collector="$1"
fixtures="$PWD/collector-fixtures"
mkdir "$fixtures"
trap 'rm -rf -- "$fixtures"' EXIT
mkdir "$fixtures/bin"
export PATH="$fixtures/bin:$PATH"
export FIXTURE_METRICS="$fixtures/input.prom"
export FIXTURE_STATUS=0

cat > "$fixtures/bin/homelab-finances-ingest" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 1 && "$1" == metrics ]]
cat "$FIXTURE_METRICS"
exit "$FIXTURE_STATUS"
SH
chmod 0755 "$fixtures/bin/homelab-finances-ingest"

write_metrics() {
  cat > "$FIXTURE_METRICS" <<EOF
# HELP finance_ingest_state_read_success Whether local state could be read.
# TYPE finance_ingest_state_read_success gauge
finance_ingest_state_read_success $1
# HELP finance_ingest_metrics_generated_timestamp_seconds Time of collection.
# TYPE finance_ingest_metrics_generated_timestamp_seconds gauge
finance_ingest_metrics_generated_timestamp_seconds $2
EOF
}

write_metrics 1 100
bash "$collector" "$fixtures/output.prom"
cmp "$FIXTURE_METRICS" "$fixtures/output.prom"
[[ "$(stat -c '%a' "$fixtures/output.prom")" == 640 ]]
[[ ! -e "$fixtures/output.prom.pending" ]]

write_metrics 0 200
export FIXTURE_STATUS=1
# The CLI need not emit optional HELP lines; promtool reports those as lint.
grep -v '^# HELP' "$FIXTURE_METRICS" > "$fixtures/no-help.prom"
cp "$fixtures/no-help.prom" "$FIXTURE_METRICS"
status=0
bash "$collector" "$fixtures/output.prom" || status=$?
[[ "$status" == 1 ]]
cmp "$FIXTURE_METRICS" "$fixtures/output.prom"
cp "$fixtures/output.prom" "$fixtures/retained.prom"

printf 'not valid metrics\n' > "$FIXTURE_METRICS"
if bash "$collector" "$fixtures/output.prom"; then
  echo "Malformed metrics replaced evidence" >&2
  exit 1
fi
cmp "$fixtures/retained.prom" "$fixtures/output.prom"
[[ ! -e "$fixtures/output.prom.pending" ]]
[[ ! -e "$fixtures/output.prom.pending.lint" ]]

write_metrics 1 250
printf 'broken{label=\n' >> "$FIXTURE_METRICS"
if bash "$collector" "$fixtures/output.prom"; then
  echo "Parse failure was mistaken for optional metadata lint" >&2
  exit 1
fi
cmp "$fixtures/retained.prom" "$fixtures/output.prom"

# Empty output (missing executable/import failure) must not erase evidence.
: > "$FIXTURE_METRICS"
if bash "$collector" "$fixtures/output.prom"; then
  echo "Empty metrics replaced evidence" >&2
  exit 1
fi
cmp "$fixtures/retained.prom" "$fixtures/output.prom"

write_metrics 1 300
export FIXTURE_STATUS=0
mkdir "$fixtures/unwritable.prom"
if bash "$collector" "$fixtures/unwritable.prom"; then
  echo "Atomic replacement failure was hidden" >&2
  exit 1
fi
[[ ! -e "$fixtures/unwritable.prom.pending" ]]
[[ -z "$(ls -A "$fixtures/unwritable.prom")" ]]
echo "Collector fixtures passed (success, nonzero failure metrics, malformed/empty output, publication failure)."
