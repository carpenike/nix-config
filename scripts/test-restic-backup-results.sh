#!/usr/bin/env bash

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: test-restic-backup-results.sh [job-name]

Runs the deployed Restic wrapper against an isolated mock binary for complete,
partial (exit 3), fatal, and TERM-interrupted results. No real repository or
production metric file is accessed.
EOF
}

case ${1:-} in
  --help|-h)
    usage
    exit 0
    ;;
esac

job=${1:-service-actual}
service="restic-backup-${job}.service"
seed_timestamp=1700000000
failures=0

if (( EUID != 0 )); then
  echo "This test must run as root" >&2
  exit 2
fi

if ! systemctl cat "$service" >/dev/null 2>&1; then
  echo "Unknown Restic backup service: $service" >&2
  exit 2
fi

service_script=$(systemctl cat "$service" --no-pager | sed -n 's/^ExecStart=//p' | awk '{print $1}' | head -1)
restic_bin=$(grep -o '/nix/store/[^" ]*-restic-[^" ]*/bin/restic' "$service_script" | head -1)
production_metric="/var/lib/node_exporter/textfile_collector/restic_backup_${job}.prom"
production_checksum=missing

if [[ -f $production_metric ]]; then
  production_checksum=$(sha256sum "$production_metric" | awk '{print $1}')
fi

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  failures=$((failures + 1))
}

check_equal() {
  local label=$1
  local actual=$2
  local expected=$3
  if [[ $actual == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected=$expected actual=${actual:-unset})"
  fi
}

run_case() {
  local mode=$1
  local expected_status=$2
  local expected_result=$3
  local expected_timestamp=$4
  local work unit metric run_status result timestamp exit_code

  work=$(mktemp -d)
  unit="restic-result-${mode}-$RANDOM"
  install -d -m 0750 -o restic-backup -g restic-backup "$work/metrics"

  cat > "$work/restic" <<'MOCK'
#!/run/current-system/sw/bin/bash
set -u

case ${1:-} in
  backup)
    case ${MOCK_RESTIC_MODE:-failed} in
      complete) exit 0 ;;
      partial) exit 3 ;;
      failed) exit 1 ;;
      interrupted)
        kill -TERM "$PPID"
        exit 143
        ;;
    esac
    ;;
  snapshots)
    printf '%s\n' '[{"summary":{"files_new":1,"data_added":2}}]'
    exit 0
    ;;
esac
exit 1
MOCK
  chmod 0755 "$work/restic"

  metric="$work/metrics/restic_backup_${job}.prom"
  cat > "$metric" <<METRIC
restic_backup_last_success_timestamp{seed="true"} $seed_timestamp
METRIC
  chown restic-backup:restic-backup "$metric"

  set +e
  systemd-run --quiet --pipe --wait --collect --unit="$unit" \
    -p User=restic-backup \
    -p Group=restic-backup \
    -p Environment=PATH=/run/current-system/sw/bin \
    -p "Environment=MOCK_RESTIC_MODE=$mode" \
    -p "BindReadOnlyPaths=$work/restic:$restic_bin" \
    -p "BindPaths=$work/metrics:/var/lib/node_exporter/textfile_collector" \
    "$service_script"
  run_status=$?
  set -e

  result=$(awk '/^restic_backup_result\{/ && $NF == 1 {
    match($0, /result="[^"]+"/)
    print substr($0, RSTART + 8, RLENGTH - 9)
    exit
  }' "$metric")
  timestamp=$(awk '/^restic_backup_last_success_timestamp\{/ {print $NF; exit}' "$metric")
  exit_code=$(awk '/^restic_backup_exit_code\{/ {print $NF; exit}' "$metric")

  check_equal "$mode-status" "$run_status" "$expected_status"
  check_equal "$mode-result" "$result" "$expected_result"
  check_equal "$mode-exit-code" "$exit_code" "$expected_status"

  if [[ $expected_timestamp == newer ]]; then
    if [[ $timestamp =~ ^[0-9]+$ ]] && (( timestamp > seed_timestamp )); then
      pass "$mode-last-success-updated"
    else
      fail "$mode-last-success-updated (actual=${timestamp:-unset})"
    fi
  else
    check_equal "$mode-last-success-preserved" "$timestamp" "$seed_timestamp"
  fi

  systemctl reset-failed "$unit.service" >/dev/null 2>&1 || true
  rm -rf "$work"
}

run_systemd_stop_case() {
  local work unit metric result timestamp exit_code

  work=$(mktemp -d)
  unit="restic-result-systemd-stop-$RANDOM"
  install -d -m 0750 -o restic-backup -g restic-backup "$work/metrics"

  cat > "$work/restic" <<'MOCK'
#!/run/current-system/sw/bin/bash
set -u

case ${1:-} in
  backup)
    /run/current-system/sw/bin/systemd-notify --ready
    exec /run/current-system/sw/bin/tail -f /dev/null
    ;;
  snapshots)
    printf '%s\n' '[]'
    exit 0
    ;;
esac
exit 1
MOCK
  chmod 0755 "$work/restic"

  metric="$work/metrics/restic_backup_${job}.prom"
  cat > "$metric" <<METRIC
restic_backup_last_success_timestamp{seed="true"} $seed_timestamp
METRIC
  chown restic-backup:restic-backup "$metric"

  systemd-run --quiet --unit="$unit" \
    -p User=restic-backup \
    -p Group=restic-backup \
    -p Type=notify \
    -p NotifyAccess=all \
    -p KillMode=mixed \
    -p Environment=PATH=/run/current-system/sw/bin \
    -p "BindReadOnlyPaths=$work/restic:$restic_bin" \
    -p "BindPaths=$work/metrics:/var/lib/node_exporter/textfile_collector" \
    "$service_script"

  if systemctl is-active --quiet "$unit.service"; then
    pass "systemd-stop-started"
  else
    fail "systemd-stop-started"
  fi

  if systemctl stop "$unit.service"; then
    pass "systemd-stop-command"
  else
    fail "systemd-stop-command"
  fi

  result=$(awk '/^restic_backup_result\{/ && $NF == 1 {
    match($0, /result="[^"]+"/)
    print substr($0, RSTART + 8, RLENGTH - 9)
    exit
  }' "$metric")
  timestamp=$(awk '/^restic_backup_last_success_timestamp\{/ {print $NF; exit}' "$metric")
  exit_code=$(awk '/^restic_backup_exit_code\{/ {print $NF; exit}' "$metric")

  check_equal "systemd-stop-result" "$result" failed
  check_equal "systemd-stop-exit-code" "$exit_code" 143
  check_equal "systemd-stop-last-success-preserved" "$timestamp" "$seed_timestamp"

  systemctl reset-failed "$unit.service" >/dev/null 2>&1 || true
  rm -rf "$work"
}

run_case complete 0 complete newer
run_case partial 3 partial preserved
run_case failed 1 failed preserved
run_case interrupted 143 failed preserved
run_systemd_stop_case

final_checksum=missing
if [[ -f $production_metric ]]; then
  final_checksum=$(sha256sum "$production_metric" | awk '{print $1}')
fi
check_equal "production-metric-unchanged" "$final_checksum" "$production_checksum"

exit "$failures"
