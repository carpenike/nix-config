#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
test_root=$(mktemp -d)
helper="$test_root/yubikey-unlock"
mock_log="$test_root/mock.log"
mock_state="$test_root/card-count"
output_file="$test_root/output"
temp_dir="$test_root/tmp"
mkdir "$temp_dir"

cleanup() {
  rm -f "$helper" "$mock_log" "$mock_state" "$output_file"
  rmdir "$temp_dir" "$test_root"
}
trap cleanup EXIT

nix eval --raw .#darwinConfigurations.rymac.config.home-manager.users.ryan.home.packages \
  --apply 'packages: (builtins.head (builtins.filter (p: (p.name or "") == "yubikey-unlock") packages)).text' \
  > "$helper"
bash -n "$helper"

fail() {
  cat "$output_file" >&2
  printf 'FAIL: %s: %s\n' "$case_name" "$*" >&2
  exit 1
}

gpg() {
  case "$*" in
    --card-status)
      printf 'card\n' >> "$MOCK_LOG"
      [[ "${LC_ALL:-}" == C ]] || return 99
      local count result
      local -a results
      count=$(<"$MOCK_STATE")
      read -r -a results <<< "$MOCK_CARDS"
      result="${results[count]:-${results[${#results[@]}-1]}}"
      printf '%s\n' "$((count + 1))" > "$MOCK_STATE"
      case "$result" in
        ready) return 0 ;;
        busy) echo 'gpg: OpenPGP card not available: Operation not supported by device' >&2 ;;
        general) echo 'gpg: OpenPGP card not available: General error' >&2 ;;
        missing) echo 'gpg: OpenPGP card not available: No such device' >&2 ;;
        *) echo "Unexpected mock card result: $result" >&2; return 99 ;;
      esac
      return 2
      ;;
    *--detach-sign*)
      printf 'sign\n' >> "$MOCK_LOG"
      if [[ "$MOCK_SIGN_STATUS" != 0 ]]; then
        echo 'gpg: signing failed: Operation cancelled' >&2
      fi
      return "$MOCK_SIGN_STATUS"
      ;;
    *) echo "Unexpected gpg invocation: $*" >&2; return 99 ;;
  esac
}

gpgconf() {
  printf 'gpgconf %s\n' "$*" >> "$MOCK_LOG"
  case "$*" in
    '--launch gpg-agent') return "$MOCK_LAUNCH_STATUS" ;;
    '--kill scdaemon') return "$MOCK_SCDAEMON_STATUS" ;;
    '--list-dirs agent-ssh-socket') echo '/mock/gpg-agent-ssh' ;;
    *) echo "Unexpected gpgconf invocation: $*" >&2; return 99 ;;
  esac
}

ps() {
  printf 'ps %s\n' "$*" >> "$MOCK_LOG"
  case "$*" in
    '-axww -o uid=,pid=,comm=')
      if [[ "$MOCK_PS_STATUS" != 0 ]]; then
        echo 'mock process enumeration failed' >&2
        return "$MOCK_PS_STATUS"
      fi
      printf '%s\n' "$MOCK_PROCESSES"
      ;;
    '-ww -p 4101 -o uid=,comm='|'-ww -p 4105 -o uid=,comm=')
      case "$MOCK_IDENTITY" in
        same) printf '501 %s\n' "$MOCK_PCSC_HELPER" ;;
        other-user) printf '502 %s\n' "$MOCK_PCSC_HELPER" ;;
        other-executable) echo '501 /unrelated/process' ;;
        gone) return 1 ;;
        *) echo "Unexpected mock identity: $MOCK_IDENTITY" >&2; return 99 ;;
      esac
      ;;
    *) echo "Unexpected ps invocation: $*" >&2; return 99 ;;
  esac
}

kill() {
  printf 'kill %s\n' "$*" >> "$MOCK_LOG"
  case "$*" in
    '-TERM 4101'|'-TERM 4105')
      if [[ "$MOCK_KILL_STATUS" != 0 ]]; then
        echo 'mock signal failed' >&2
      fi
      return "$MOCK_KILL_STATUS"
      ;;
    *) echo "Unsafe signal attempted: $*" >&2; return 99 ;;
  esac
}

id() {
  [[ "$*" == -u ]] || return 99
  printf '%s\n' "$MOCK_UID"
}

sleep() {
  [[ "$*" == 1 ]] || return 99
  printf 'sleep\n' >> "$MOCK_LOG"
}

ssh-add() {
  printf 'ssh\n' >> "$MOCK_LOG"
  [[ $# == 2 && "$1" == -T && -r "$2" && "$SSH_AUTH_SOCK" == /mock/gpg-agent-ssh ]] || return 99
  return "$MOCK_SSH_STATUS"
}

sops() {
  printf 'sops\n' >> "$MOCK_LOG"
  [[ $# == 2 && "$1" == --decrypt && -r "$2" ]] || return 99
  return "$MOCK_SOPS_STATUS"
}

# Exported functions override both binaries and Bash's kill builtin in the
# generated helper, even after writeShellApplication sets its runtime PATH.
export -f gpg gpgconf ps kill id sleep ssh-add sops
export MOCK_LOG="$mock_log" MOCK_STATE="$mock_state"

pcsc_helper='/System/Library/Frameworks/PCSC.framework/Versions/A/XPCServices/com.apple.ctkpcscd.xpc/Contents/MacOS/com.apple.ctkpcscd'
processes="0 4100 $pcsc_helper
501 4101 $pcsc_helper
502 4102 $pcsc_helper
501 4103 $pcsc_helper-unrelated
501 4104 /unrelated/com.apple.ctkpcscd
501 4105 $pcsc_helper
501 0 $pcsc_helper
501 -1 $pcsc_helper
501 not-a-pid $pcsc_helper"

run_case() {
  case_name=$1
  local expected_status=$2 cards=$3 status=0
  shift 3
  : > "$mock_log"
  printf '0\n' > "$mock_state"
  env \
    TMPDIR="$temp_dir" \
    LC_ALL=POSIX \
    MOCK_CARDS="$cards" \
    MOCK_UID="${MOCK_UID:-501}" \
    MOCK_PCSC_HELPER="$pcsc_helper" \
    MOCK_PROCESSES="${MOCK_PROCESSES-$processes}" \
    MOCK_IDENTITY="${MOCK_IDENTITY:-same}" \
    MOCK_LAUNCH_STATUS="${MOCK_LAUNCH_STATUS:-0}" \
    MOCK_SCDAEMON_STATUS="${MOCK_SCDAEMON_STATUS:-0}" \
    MOCK_PS_STATUS="${MOCK_PS_STATUS:-0}" \
    MOCK_KILL_STATUS="${MOCK_KILL_STATUS:-0}" \
    MOCK_SIGN_STATUS="${MOCK_SIGN_STATUS:-0}" \
    MOCK_SSH_STATUS="${MOCK_SSH_STATUS:-0}" \
    MOCK_SOPS_STATUS="${MOCK_SOPS_STATUS:-0}" \
    bash "$helper" "$@" > "$output_file" 2>&1 || status=$?
  [[ "$status" == "$expected_status" ]] || fail "exit $status, expected $expected_status"
  [[ -z "$(find "$temp_dir" -type f -print -quit)" ]] || fail "temporary files were not cleaned up"
  if (( status != 0 )) && grep -Fq 'YubiKey unlocked for' "$output_file"; then
    fail "failed operation reported a successful unlock"
  fi
}

assert_count() {
  local count
  count=$(grep -Fxc -- "$1" "$mock_log") || [[ "$count" == 0 ]] || fail "cannot read mock log"
  [[ "$count" == "$2" ]] || fail "'$1' ran $count times, expected $2"
}

assert_output() {
  grep -Fq -- "$1" "$output_file" || fail "missing output: $1"
}

assert_no_unlock() {
  assert_count sign 0
  assert_count ssh 0
  assert_count sops 0
}

assert_unlocked() {
  assert_count sign 1
  assert_count ssh 1
  assert_count sops 1
  assert_output 'YubiKey unlocked for GPG signing, SSH authentication, and SOPS decryption.'
}

run_case healthy 0 ready
assert_count card 1
assert_count 'gpgconf --kill scdaemon' 0
assert_unlocked

run_case healthy-recover 0 ready --recover
assert_count card 1
assert_count 'gpgconf --kill scdaemon' 0
assert_count 'ps -axww -o uid=,pid=,comm=' 0
assert_unlocked

run_case transient-general 0 'general general ready'
assert_count card 3
assert_count 'gpgconf --kill scdaemon' 0
assert_unlocked

run_case transient-busy 0 'busy ready'
assert_count card 2
assert_count 'gpgconf --kill scdaemon' 0
assert_unlocked

run_case general-exhausted 1 general --recover
assert_count card 3
assert_count 'gpgconf --kill scdaemon' 0
assert_count 'ps -axww -o uid=,pid=,comm=' 0
assert_output 'General error'
assert_no_unlock

run_case scdaemon-recovery 0 'busy busy busy general ready'
assert_count card 5
assert_count 'gpgconf --kill scdaemon' 1
assert_count 'ps -axww -o uid=,pid=,comm=' 0
assert_unlocked

run_case recovery-opt-in 1 busy
assert_count card 6
assert_count 'gpgconf --kill scdaemon' 1
assert_count 'ps -axww -o uid=,pid=,comm=' 0
assert_output 'yku --recover'
assert_no_unlock

run_case pcsc-recovery 0 'busy busy busy busy busy busy general busy ready' --recover
assert_count card 9
assert_count 'gpgconf --kill scdaemon' 2
assert_count 'ps -axww -o uid=,pid=,comm=' 1
assert_count 'kill -TERM 4101' 1
assert_count 'kill -TERM 4105' 1
assert_count 'kill -TERM 4100' 0
assert_count 'kill -TERM 4102' 0
assert_count 'kill -TERM 4103' 0
assert_count 'kill -TERM 4104' 0
assert_count 'kill -TERM 0' 0
assert_count 'kill -TERM -1' 0
assert_count 'kill -TERM not-a-pid' 0
assert_unlocked

run_case pcsc-still-busy 1 busy --recover
assert_count card 9
assert_count 'gpgconf --kill scdaemon' 2
assert_count 'ps -axww -o uid=,pid=,comm=' 1
assert_count 'kill -TERM 4101' 1
assert_count 'kill -TERM 4105' 1
assert_output 'Recovery did not restore card access.'
assert_no_unlock

MOCK_PROCESSES='' run_case no-helpers 1 busy --recover
assert_count card 9
assert_count 'kill -TERM 4101' 0
assert_output 'No matching user-owned PC/SC helpers were restarted.'
assert_no_unlock

for identity in other-user other-executable gone; do
  MOCK_IDENTITY="$identity" run_case "identity-$identity" 1 busy --recover
  assert_count 'ps -ww -p 4101 -o uid=,comm=' 1
  assert_count 'kill -TERM 4101' 0
  assert_count 'kill -TERM 4105' 0
  assert_output 'skipping it.'
  assert_no_unlock
done

MOCK_UID=0 run_case refuse-root 1 busy --recover
assert_count 'ps -axww -o uid=,pid=,comm=' 0
assert_output 'Refusing PC/SC recovery as root.'
assert_no_unlock

run_case missing-card 1 missing --recover
assert_count card 1
assert_count 'gpgconf --kill scdaemon' 0
assert_count 'ps -axww -o uid=,pid=,comm=' 0
assert_output 'No such device'
assert_no_unlock

run_case error-changes 1 'busy busy busy missing' --recover
assert_count card 4
assert_count 'gpgconf --kill scdaemon' 1
assert_count 'ps -axww -o uid=,pid=,comm=' 0
assert_no_unlock

MOCK_LAUNCH_STATUS=23 run_case launch-failure 23 ready --recover
assert_count card 0
assert_no_unlock

MOCK_SCDAEMON_STATUS=24 run_case scdaemon-failure 24 busy --recover
assert_count card 3
assert_count 'ps -axww -o uid=,pid=,comm=' 0
assert_no_unlock

MOCK_PS_STATUS=25 run_case enumeration-failure 25 busy --recover
assert_count card 6
assert_count 'kill -TERM 4101' 0
assert_output 'mock process enumeration failed'
assert_no_unlock

MOCK_KILL_STATUS=26 run_case signal-failure 1 busy --recover
assert_count card 6
assert_count 'kill -TERM 4101' 1
assert_count 'kill -TERM 4105' 0
assert_output 'recovery aborted.'
assert_no_unlock

MOCK_SIGN_STATUS=27 run_case signing-cancelled 27 ready --recover
assert_count card 1
assert_count sign 1
assert_count ssh 0
assert_count sops 0
assert_count 'gpgconf --kill scdaemon' 0
assert_output 'Operation cancelled'

MOCK_SIGN_STATUS=27 run_case signing-cancelled-after-recovery 27 'busy busy busy busy busy busy ready' --recover
assert_count card 7
assert_count 'gpgconf --kill scdaemon' 2
assert_count 'ps -axww -o uid=,pid=,comm=' 1
assert_count sign 1
assert_count ssh 0
assert_count sops 0
assert_output 'Operation cancelled'

MOCK_SSH_STATUS=28 run_case ssh-failure 28 ready --recover
assert_count card 1
assert_count sign 1
assert_count ssh 1
assert_count sops 0
assert_count 'gpgconf --kill scdaemon' 0

MOCK_SOPS_STATUS=29 run_case sops-failure 29 ready --recover
assert_count card 1
assert_count sign 1
assert_count ssh 1
assert_count sops 1
assert_count 'gpgconf --kill scdaemon' 0

for flag in --help -h; do
  run_case help 0 ready "$flag"
  [[ ! -s "$mock_log" ]] || fail "help touched smartcard state"
  assert_output 'Usage: yubikey-unlock [--recover]'
done

run_case unknown-option 2 ready --invalid
[[ ! -s "$mock_log" ]] || fail "invalid option touched smartcard state"
assert_output 'Unknown argument: --invalid'

run_case extra-argument 2 ready --recover unexpected
[[ ! -s "$mock_log" ]] || fail "extra argument touched smartcard state"

printf '%s\n' 'YubiKey unlock recovery regressions passed.'
