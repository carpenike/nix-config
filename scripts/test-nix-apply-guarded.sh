#!/usr/bin/env bash

set -euo pipefail

if (( $# != 1 )); then
  echo "usage: $0 <nix-apply-guarded.sh>" >&2
  exit 2
fi

wrapper=$1
test_root=$(mktemp -d)
mock_bin="$test_root/bin"
mock_log="$test_root/mock.log"
repo_root="$test_root/repo"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$mock_bin" "$repo_root"

printf '#!%s\n' "$(command -v bash)" > "$mock_bin/ssh"
cat >> "$mock_bin/ssh" <<'MOCK_SSH'
set -euo pipefail

mock_log=${MOCK_LOG:?}
joined=" $* "

if [[ "$joined" == *" test -x /run/current-system/sw/bin/nixos-deploy-backup-guard "* ]]; then
  printf 'available\n' >> "$mock_log"
  exit 0
fi

if [[ "$joined" == *"/nixos-deploy-backup-guard recover "* ]]; then
  printf 'recover\n' >> "$mock_log"
  echo "No abandoned deployment guard state found"
  exit 0
fi

if [[ "$joined" == *"/nixos-deploy-backup-guard hold "* ]]; then
  deployment_id=${!#}
  printf 'hold %s\n' "$deployment_id" >> "$mock_log"
  if (( ${MOCK_GUARD_ACQUIRE_STATUS:-0} != 0 )); then
    echo "Another deployment backup guard already owns the lock" >&2
    exit "${MOCK_GUARD_ACQUIRE_STATUS}"
  fi

  printf 'READY %s timers=3\n' "$deployment_id"
  if [[ "${MOCK_GUARD_EXPIRE:-0}" == 1 ]]; then
    echo "Deployment lease ended before release; restoring backup timers" >&2
    echo "RESTORED recorded=3 active=3 removed=0 dropins=0"
    exit 1
  fi
  if ! IFS= read -r command; then
    echo "lease input closed" >&2
    exit 1
  fi
  printf '%s\n' "$command" >> "$mock_log"
  if [[ "$command" != "release $deployment_id" ]]; then
    echo "unexpected lease command: $command" >&2
    exit 1
  fi
  if (( ${MOCK_GUARD_RELEASE_STATUS:-0} != 0 )); then
    echo "mock restoration failed" >&2
    exit "${MOCK_GUARD_RELEASE_STATUS}"
  fi
  echo "RESTORED recorded=3 active=3 removed=0 dropins=0"
  exit 0
fi

if [[ "$joined" == *" bash -s -- "* ]]; then
  cat >/dev/null
  printf 'reset-transients\n' >> "$mock_log"
  exit 0
fi

printf 'unexpected ssh invocation: %s\n' "$*" >&2
exit 2
MOCK_SSH
chmod +x "$mock_bin/ssh"

printf '#!%s\n' "$(command -v bash)" > "$mock_bin/nix-shell"
cat >> "$mock_bin/nix-shell" <<'MOCK_NIX_SHELL'
set -euo pipefail
printf 'rebuild\n' >> "${MOCK_LOG:?}"
printf '%s\n' "${MOCK_REBUILD_OUTPUT:-mock rebuild}"
exit "${MOCK_REBUILD_STATUS:-0}"
MOCK_NIX_SHELL
chmod +x "$mock_bin/nix-shell"

run_case() {
  local name=$1
  local rebuild_status=$2
  local acquire_status=$3
  local release_status=$4
  local expire_guard=$5
  local expected_status=$6
  local output_file="$test_root/$name.out"
  local status=0

  : > "$mock_log"
  set +e
  env \
    PATH="$mock_bin:$PATH" \
    MOCK_LOG="$mock_log" \
    MOCK_REBUILD_STATUS="$rebuild_status" \
    MOCK_GUARD_ACQUIRE_STATUS="$acquire_status" \
    MOCK_GUARD_RELEASE_STATUS="$release_status" \
    MOCK_GUARD_EXPIRE="$expire_guard" \
    bash "$wrapper" ryan forge example.test "$repo_root" > "$output_file" 2>&1
  status=$?
  set -e

  if (( status != expected_status )); then
    cat "$output_file" >&2
    fail "$name exited with $status; expected $expected_status"
  fi

  case "$name" in
    success)
      grep -q '^rebuild$' "$mock_log" || fail "successful deployment skipped rebuild"
      grep -q '^release forge-' "$mock_log" || fail "successful deployment did not release guard"
      grep -q '^RESTORED recorded=3 active=3 removed=0 dropins=0$' "$output_file" \
        || fail "successful restoration summary missing"
      ;;
    build-failure)
      grep -q '^rebuild$' "$mock_log" || fail "failed deployment skipped rebuild"
      grep -q '^release forge-' "$mock_log" || fail "build failure did not release guard"
      grep -q 'nixos-rebuild failed during the build phase' "$output_file" \
        || fail "build failure classification missing"
      ;;
    restore-failure)
      grep -q '^release forge-' "$mock_log" || fail "restoration failure never sent release"
      grep -q 'Target deployment guard failed while restoring backup timers' "$output_file" \
        || fail "restoration failure was not surfaced"
      ;;
    concurrent-owner)
      ! grep -q '^rebuild$' "$mock_log" || fail "concurrent deployment reached rebuild"
      ! grep -q '^release forge-' "$mock_log" || fail "unowned guard was released"
      grep -q 'Failed to acquire the target deployment backup lease' "$output_file" \
        || fail "concurrent owner rejection was not surfaced"
      ;;
    lease-expired)
      grep -q '^rebuild$' "$mock_log" || fail "expired lease skipped rebuild"
      grep -q 'Deployment lease ended before release' "$output_file" \
        || fail "lease expiry diagnostic was not surfaced"
      grep -q 'Target deployment guard failed while restoring backup timers' "$output_file" \
        || fail "expired lease was not reported as a deployment failure"
      ;;
  esac
}

run_case success 0 0 0 0 0
run_case build-failure 42 0 0 0 42
run_case restore-failure 0 0 17 0 1
run_case concurrent-owner 0 75 0 0 1
run_case lease-expired 0 0 0 1 1

echo "All guarded deployment wrapper tests passed"
