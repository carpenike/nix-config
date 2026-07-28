#!/usr/bin/env bash

set -euo pipefail

if (( $# != 2 )); then
  echo "usage: $0 <nixos-deploy-backup-guard> <nixos-deploy-backup-guard-metrics>" >&2
  exit 2
fi

guard_command=$1
metrics_command=$2
test_root=$(mktemp -d)
state_dir="$test_root/state"
runtime_dir="$test_root/run"
systemd_runtime_dir="$test_root/systemd"
marker_file="$test_root/paused-timers"
lock_file="$test_root/guard.lock"
expected_timers_file="$test_root/expected-timers"
metrics_file="$test_root/guard.prom"
mock_systemctl="$test_root/systemctl"
mock_systemd_run="$test_root/systemd-run"
guard_pid=""
lease_fd=""

timers=(
  restic-backup-alpha.timer
  sanoid.timer
  syncoid-tank-beta.timer
)

cleanup() {
  if [[ -n "$guard_pid" ]] && kill -0 "$guard_pid" 2>/dev/null; then
    kill "$guard_pid" 2>/dev/null || true
    wait "$guard_pid" 2>/dev/null || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

printf '#!%s\n' "$(command -v bash)" > "$mock_systemctl"
cat >> "$mock_systemctl" <<'MOCK_SYSTEMCTL'
set -euo pipefail

state_dir=${MOCK_SYSTEMD_STATE:?}
command=$1
shift

is_listed() {
  local file=$1
  local value=$2
  grep -Fxq "$value" "$file"
}

remove_active() {
  local timer=$1
  grep -Fvx "$timer" "$state_dir/active" > "$state_dir/active.tmp" || true
  mv "$state_dir/active.tmp" "$state_dir/active"
}

case "$command" in
  list-units)
    if [[ " $* " == *" --type=timer "* && " $* " == *" --state=active "* ]]; then
      while IFS= read -r timer; do
        [[ -n "$timer" ]] || continue
        printf '%s loaded active waiting Mock timer\n' "$timer"
      done < "$state_dir/active"
    fi
    ;;
  list-jobs | daemon-reload)
    ;;
  cat)
    is_listed "$state_dir/exists" "$1"
    ;;
  stop)
    for timer in "$@"; do
      remove_active "$timer"
    done
    ;;
  start)
    status=0
    for timer in "$@"; do
      if ! is_listed "$state_dir/exists" "$timer" || is_listed "$state_dir/fail-start" "$timer"; then
        status=1
        continue
      fi
      if ! is_listed "$state_dir/active" "$timer"; then
        printf '%s\n' "$timer" >> "$state_dir/active"
      fi
    done
    sort -u -o "$state_dir/active" "$state_dir/active"
    exit "$status"
    ;;
  is-active)
    [[ "${1:-}" == --quiet ]] && shift
    is_listed "$state_dir/active" "$1"
    ;;
  *)
    echo "Unexpected systemctl command: $command $*" >&2
    exit 2
    ;;
esac
MOCK_SYSTEMCTL
chmod +x "$mock_systemctl"

printf '#!%s\n' "$(command -v bash)" > "$mock_systemd_run"
cat >> "$mock_systemd_run" <<'MOCK_SYSTEMD_RUN'
exit 0
MOCK_SYSTEMD_RUN
chmod +x "$mock_systemd_run"

reset_fixture() {
  rm -rf "$state_dir" "$runtime_dir" "$systemd_runtime_dir"
  mkdir -p "$state_dir" "$runtime_dir" "$systemd_runtime_dir"
  printf '%s\n' "${timers[@]}" > "$state_dir/exists"
  printf '%s\n' "${timers[@]}" > "$state_dir/active"
  printf '%s\n' "${timers[@]}" > "$expected_timers_file"
  : > "$state_dir/fail-start"
  rm -f "$marker_file" "$lock_file"
}

run_metrics() {
  env \
    MOCK_SYSTEMD_STATE="$state_dir" \
    NIXOS_DEPLOY_GUARD_RUNTIME_DIR="$runtime_dir" \
    NIXOS_DEPLOY_GUARD_MARKER_FILE="$marker_file" \
    NIXOS_DEPLOY_GUARD_EXPECTED_TIMERS_FILE="$expected_timers_file" \
    NIXOS_DEPLOY_GUARD_METRICS_FILE="$metrics_file" \
    NIXOS_DEPLOY_GUARD_SYSTEMCTL="$mock_systemctl" \
    "$metrics_command"
}

run_guard() {
  env \
    MOCK_SYSTEMD_STATE="$state_dir" \
    NIXOS_DEPLOY_GUARD_TEST_MODE=1 \
    NIXOS_DEPLOY_GUARD_RUNTIME_DIR="$runtime_dir" \
    NIXOS_DEPLOY_GUARD_MARKER_FILE="$marker_file" \
    NIXOS_DEPLOY_GUARD_LOCK_FILE="$lock_file" \
    NIXOS_DEPLOY_GUARD_SYSTEMD_RUNTIME_DIR="$systemd_runtime_dir" \
    NIXOS_DEPLOY_GUARD_SYSTEMCTL="$mock_systemctl" \
    NIXOS_DEPLOY_GUARD_SYSTEMD_RUN="$mock_systemd_run" \
    NIXOS_DEPLOY_GUARD_TRUE=true \
    NIXOS_DEPLOY_GUARD_MAX_HOLD_SECONDS="${TEST_MAX_HOLD_SECONDS:-30}" \
    "$guard_command" "$@"
}

assert_restored() {
  local output_file=$1
  if [[ -e "$marker_file" ]]; then
    cat "$output_file" >&2
    fail "pause marker remains after $(basename "$output_file")"
  fi
  if find "$systemd_runtime_dir" -name 90-nixos-apply-guard.conf -print -quit | grep -q .; then
    cat "$output_file" >&2
    fail "guard drop-in remains"
  fi
  diff -u <(sort "$state_dir/exists") <(sort "$state_dir/active") \
    || fail "active timers do not match surviving timers"
}

wait_for_ready() {
  local output_file=$1
  local deployment_id=$2
  for _ in $(seq 1 100); do
    if grep -q "^READY $deployment_id timers=" "$output_file" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$guard_pid" 2>/dev/null; then
      cat "$output_file" >&2
      fail "guard exited before READY"
    fi
    sleep 0.05
  done
  fail "timed out waiting for guard readiness"
}

start_held_guard() {
  local deployment_id=$1
  local output_file=$2
  local fifo="$test_root/lease-$deployment_id"

  mkfifo "$fifo"
  exec {lease_fd}<> "$fifo"
  run_guard hold "$deployment_id" < "$fifo" > "$output_file" 2>&1 &
  guard_pid=$!
  wait_for_ready "$output_file" "$deployment_id"
}

release_held_guard() {
  local deployment_id=$1
  local expect_success=$2
  local status=0

  printf 'release %s\n' "$deployment_id" >&"$lease_fd"
  exec {lease_fd}>&-
  wait "$guard_pid" || status=$?
  guard_pid=""

  if [[ "$expect_success" == true && "$status" -ne 0 ]]; then
    fail "guard release failed with status $status"
  fi
  if [[ "$expect_success" == false && "$status" -eq 0 ]]; then
    fail "guard release unexpectedly succeeded"
  fi
}

reset_fixture
if run_guard hold eof-test </dev/null > "$test_root/eof.out" 2>&1; then
  fail "EOF lease loss unexpectedly returned success"
fi
assert_restored "$test_root/eof.out"
grep -q '^RESTORED recorded=3 active=3 removed=0 dropins=0$' "$test_root/eof.out" \
  || fail "EOF cleanup summary missing"

reset_fixture
start_held_guard first-owner "$test_root/first-owner.out"
if run_guard hold second-owner </dev/null > "$test_root/second-owner.out" 2>&1; then
  fail "concurrent guard unexpectedly acquired the lock"
fi
grep -q 'Another deployment backup guard already owns' "$test_root/second-owner.out" \
  || fail "concurrent guard rejection missing"
[[ "$(cat "$runtime_dir/owner-id")" == first-owner ]] \
  || fail "concurrent guard overwrote the active owner"
[[ ! -s "$state_dir/active" ]] \
  || fail "concurrent guard restored timers owned by the active deployment"
run_metrics
grep -q '^nixos_deploy_backup_guard_owner_alive 1$' "$metrics_file" \
  || fail "live guard owner was not detected"
grep -q '^nixos_deploy_backup_guard_active 1$' "$metrics_file" \
  || fail "active guard metric is incorrect"
owner_process_start=$(cat "$runtime_dir/owner-process-start")
printf '0\n' > "$runtime_dir/owner-process-start"
run_metrics
grep -q '^nixos_deploy_backup_guard_owner_alive 0$' "$metrics_file" \
  || fail "PID start-time mismatch was not detected"
printf '%s\n' "$owner_process_start" > "$runtime_dir/owner-process-start"
release_held_guard first-owner true
assert_restored "$test_root/first-owner.out"

reset_fixture
TEST_MAX_HOLD_SECONDS=1 start_held_guard lease-timeout "$test_root/lease-timeout.out"
timeout_status=0
wait "$guard_pid" || timeout_status=$?
guard_pid=""
exec {lease_fd}>&-
(( timeout_status != 0 )) || fail "expired lease unexpectedly returned success"
assert_restored "$test_root/lease-timeout.out"
grep -q 'Deployment lease ended before release' "$test_root/lease-timeout.out" \
  || fail "lease expiry diagnostic missing"

reset_fixture
start_held_guard removed-timer "$test_root/removed-timer.out"
grep -Fvx 'syncoid-tank-beta.timer' "$state_dir/exists" > "$state_dir/exists.tmp"
mv "$state_dir/exists.tmp" "$state_dir/exists"
release_held_guard removed-timer true
assert_restored "$test_root/removed-timer.out"
grep -q '^RESTORED recorded=3 active=2 removed=1 dropins=0$' "$test_root/removed-timer.out" \
  || fail "removed timer was not classified correctly"

reset_fixture
start_held_guard failed-restart "$test_root/failed-restart.out"
printf '%s\n' 'restic-backup-alpha.timer' > "$state_dir/fail-start"
release_held_guard failed-restart false
[[ -e "$marker_file" ]] || fail "failed restoration removed the pause marker"
[[ "$(cat "$runtime_dir/last-restore-success")" == 0 ]] \
  || fail "failed restoration metric was not recorded"
: > "$state_dir/fail-start"
run_guard recover > "$test_root/recover.out" 2>&1
assert_restored "$test_root/recover.out"
[[ "$(cat "$runtime_dir/last-restore-success")" == 1 ]] \
  || fail "successful recovery metric was not recorded"
[[ ! -e "$runtime_dir/owner-id" && ! -e "$runtime_dir/owner-pid" && ! -e "$runtime_dir/owner-process-start" && ! -e "$runtime_dir/owner-started" ]] \
  || fail "successful recovery retained stale owner metadata"

run_metrics
grep -q '^nixos_deploy_backup_guard_active 0$' "$metrics_file" \
  || fail "idle guard metric is incorrect"
grep -q '^nixos_deploy_backup_timers_expected 3$' "$metrics_file" \
  || fail "expected timer count metric is incorrect"
grep -q '^nixos_deploy_backup_timers_active 3$' "$metrics_file" \
  || fail "active timer count metric is incorrect"
grep -q '^nixos_deploy_backup_timers_inactive 0$' "$metrics_file" \
  || fail "inactive timer count metric is incorrect"
grep -q '^nixos_deploy_backup_guard_last_restore_success 1$' "$metrics_file" \
  || fail "restoration status metric is incorrect"
[[ "$(grep -c '^nixos_deploy_backup_timer_expected{' "$metrics_file")" == 3 ]] \
  || fail "per-timer expected metrics are incomplete"
[[ "$(grep -c '^nixos_deploy_backup_timer_active{' "$metrics_file")" == 3 ]] \
  || fail "per-timer active metrics are incomplete"

echo "All deployment backup guard fault tests passed"
