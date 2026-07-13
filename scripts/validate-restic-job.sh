#!/usr/bin/env bash

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: validate-restic-job.sh <job-name> [--run] [--expect complete|partial|failed]

Validates one generated restic-backup-<job-name>.service on a NixOS host.
Use --run to pause its timer, execute the backup, and restore the timer.
EOF
}

if (( $# < 1 )); then
  usage >&2
  exit 2
fi

job=$1
shift
run_job=false
expected=complete

while (( $# > 0 )); do
  case $1 in
    --run)
      run_job=true
      ;;
    --expect)
      shift
      if (( $# == 0 )); then
        echo "--expect requires a value" >&2
        exit 2
      fi
      expected=$1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case $expected in
  complete|partial|failed) ;;
  *)
    echo "Invalid expected result: $expected" >&2
    exit 2
    ;;
esac

if (( EUID != 0 )); then
  echo "This validator must run as root" >&2
  exit 2
fi

service="restic-backup-${job}.service"
timer="restic-backup-${job}.timer"
snapshot_service="zfs-snapshot-${job}.service"
metric="/var/lib/node_exporter/textfile_collector/restic_backup_${job}.prom"
timer_was_active=false
failures=0

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
  local wanted=$3
  if [[ $actual == "$wanted" ]]; then
    pass "$label"
  else
    fail "$label (expected=$wanted actual=${actual:-unset})"
  fi
}

# Invoked through the EXIT trap when --run pauses an active timer.
# shellcheck disable=SC2329
finish() {
  local status=$?
  trap - EXIT

  if [[ $timer_was_active == true ]]; then
    if systemctl start "$timer"; then
      pass "timer-restored"
    else
      fail "timer-restored"
    fi
  fi

  if (( failures > 0 )); then
    status=$failures
  fi
  exit "$status"
}

if ! systemctl cat "$service" >/dev/null 2>&1; then
  echo "Unknown Restic backup service: $service" >&2
  exit 2
fi

if systemctl is-active --quiet "$timer"; then
  timer_was_active=true
fi

if [[ $run_job == true ]]; then
  if systemctl cat "$snapshot_service" >/dev/null 2>&1; then
    helper=$(systemctl cat "$snapshot_service" --no-pager | sed -n 's/^ExecStart=//p' | head -1)
    # Match the literal variable reference embedded in the generated helper.
    # shellcheck disable=SC2016
    dataset_key=$(sed -n 's/.*DATASET_LOCK="\$LOCK_DIR\/\([^"]*\)".*/\1/p' "$helper" | head -1)
    if [[ -n $dataset_key ]] && systemctl is-active --quiet "syncoid-${dataset_key}.service"; then
      echo "Refusing to overlap with syncoid-${dataset_key}.service" >&2
      exit 2
    fi
  fi

  if [[ $timer_was_active == true ]]; then
    if systemctl stop "$timer"; then
      pass "timer-paused"
    else
      echo "Failed to pause $timer" >&2
      exit 2
    fi
  fi
  trap finish EXIT

  systemctl reset-failed "$service" >/dev/null 2>&1 || true
  if systemctl start --wait "$service"; then
    pass "service-command"
  else
    if [[ $expected == complete ]]; then
      fail "service-command"
    else
      pass "service-command-failed-as-expected"
    fi
  fi

  # BindsTo stops the snapshot unit asynchronously after the Restic oneshot
  # exits. Join that stop job before checking clone, snapshot, and lock state.
  if systemctl cat "$snapshot_service" >/dev/null 2>&1; then
    if systemctl stop "$snapshot_service"; then
      pass "snapshot-cleanup-joined"
    else
      fail "snapshot-cleanup-joined"
    fi
  fi
fi

result=$(systemctl show "$service" -p Result --value)
status=$(systemctl show "$service" -p ExecMainStatus --value)
invocation=$(systemctl show "$service" -p InvocationID --value)

case $expected in
  complete)
    check_equal "unit-result" "$result" success
    check_equal "exit-code" "$status" 0
    ;;
  partial)
    check_equal "unit-result" "$result" exit-code
    check_equal "exit-code" "$status" 3
    ;;
  failed)
    if [[ $result == success ]]; then
      fail "unit-result (unexpected success)"
    else
      pass "unit-result"
    fi
    ;;
esac

if [[ -f $metric ]]; then
  pass "metric-present"
  for state in complete partial failed; do
    value=$(awk -v wanted="$state" '
      /^restic_backup_result\{/ && index($0, "result=\"" wanted "\"") { print $NF; exit }
    ' "$metric")
    wanted_value=0
    if [[ $state == "$expected" ]]; then
      wanted_value=1
    fi
    check_equal "metric-$state" "$value" "$wanted_value"
  done
else
  fail "metric-present"
fi

if [[ -n $invocation ]]; then
  journal_is_partial=false
  if journalctl _SYSTEMD_INVOCATION_ID="$invocation" --no-pager -o cat \
    | grep -qiE 'permission denied|exit code 3|backup incomplete'; then
    journal_is_partial=true
  fi

  case $expected in
    complete)
      if [[ $journal_is_partial == false ]]; then pass "journal-complete"; else fail "journal-complete"; fi
      ;;
    partial)
      if [[ $journal_is_partial == true ]]; then pass "journal-reported-incomplete"; else fail "journal-reported-incomplete"; fi
      ;;
    failed)
      pass "journal-inspected"
      ;;
  esac
else
  fail "invocation-present"
fi

if systemctl cat "$snapshot_service" >/dev/null 2>&1; then
  helper=$(systemctl cat "$snapshot_service" --no-pager | sed -n 's/^ExecStart=//p' | head -1)
  # Match the literal variable reference embedded in the generated helper.
  # shellcheck disable=SC2016
  dataset_key=$(sed -n 's/.*DATASET_LOCK="\$LOCK_DIR\/\([^"]*\)".*/\1/p' "$helper" | head -1)

  if zfs list "tank/temp/clone-${job}" >/dev/null 2>&1; then
    fail "clone-cleanup"
  else
    pass "clone-cleanup"
  fi

  if zfs list -H -t snapshot -o name 2>/dev/null | grep -Fq "@backup-${job}"; then
    fail "snapshot-cleanup"
  else
    pass "snapshot-cleanup"
  fi

  if [[ -n $dataset_key && -e /run/lock/backup-active/$dataset_key ]]; then
    fail "lock-cleanup"
  else
    pass "lock-cleanup"
  fi
fi

if [[ $timer_was_active == true && $run_job == false ]]; then
  if systemctl is-active --quiet "$timer"; then
    pass "timer-active"
  else
    fail "timer-active"
  fi
fi

exit "$failures"
