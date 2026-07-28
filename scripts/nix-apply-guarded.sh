#!/usr/bin/env bash

set -uo pipefail

if (( $# != 4 )); then
  echo "usage: $0 <ssh-user> <host> <domain> <repo-root>" >&2
  exit 2
fi

ssh_user=$1
host=$2
domain=$3
repo_root=$4
remote_host="${ssh_user}@${host}.${domain}"
rebuild_log=$(mktemp)
legacy_timers_paused=false
target_guard_available=false
target_guard_held=false
target_guard_pid=""
target_guard_read_fd=""
target_guard_write_fd=""
deployment_id="${host}-$(date -u +%Y%m%dT%H%M%SZ)-$$"

cd "$repo_root" || exit 1

reset_transient_units() {
  local require_healthy=${1:-false}

  ssh "$remote_host" bash -s -- "$require_healthy" <<'RESET_TRANSIENTS'
set -euo pipefail
require_healthy=$1

while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue

  if [[ "$require_healthy" == true ]]; then
    container_id=${unit:0:64}
    if sudo podman container exists "$container_id"; then
      state=$(sudo podman inspect "$container_id" --format '{{.State.Status}}')
      health=$(sudo podman inspect "$container_id" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
      if [[ "$state" != running || ( "$health" != healthy && "$health" != starting && "$health" != none ) ]]; then
        echo "Refusing to clear transient unit $unit: state=$state health=$health" >&2
        exit 1
      fi
    fi
  fi

  sudo systemctl reset-failed "$unit"
done < <(
  systemctl --failed --no-pager --no-legend --plain --state=failed \
    | awk '{ print $1 }' \
    | grep -E '^[0-9a-f]{64}(-startup)?-[0-9a-f]+\.service$' \
    || true
)
RESET_TRANSIENTS
}

target_guard_is_available() {
  ssh "$remote_host" \
    'test -x /run/current-system/sw/bin/nixos-deploy-backup-guard'
}

recover_target_guard() {
  ssh "$remote_host" \
    sudo -n /run/current-system/sw/bin/nixos-deploy-backup-guard recover
}

start_target_guard() {
  local line
  local ready=false
  local guard_status=0

  coproc TARGET_GUARD_PROCESS {
    ssh "$remote_host" \
      sudo -n /run/current-system/sw/bin/nixos-deploy-backup-guard hold "$deployment_id"
  }
  target_guard_pid=$TARGET_GUARD_PROCESS_PID
  target_guard_read_fd=${TARGET_GUARD_PROCESS[0]}
  target_guard_write_fd=${TARGET_GUARD_PROCESS[1]}

  while IFS= read -r -u "$target_guard_read_fd" line; do
    printf '%s\n' "$line"
    if [[ "$line" == "READY $deployment_id timers="* ]]; then
      ready=true
      break
    fi
  done

  if [[ "$ready" != true ]]; then
    wait "$target_guard_pid" || guard_status=$?
    exec {target_guard_read_fd}<&-
    exec {target_guard_write_fd}>&-
    target_guard_read_fd=""
    target_guard_write_fd=""
    echo "Target deployment guard exited before acquiring the backup lease (status $guard_status)" >&2
    return 1
  fi

  target_guard_held=true
}

release_target_guard() {
  local line
  local guard_status=0

  if [[ "$target_guard_held" != true ]]; then
    return 0
  fi

  if ! printf 'release %s\n' "$deployment_id" >&"$target_guard_write_fd"; then
    echo "Failed to send the release command to the target deployment guard" >&2
    guard_status=1
  fi
  exec {target_guard_write_fd}>&-
  target_guard_write_fd=""

  while IFS= read -r -u "$target_guard_read_fd" line; do
    printf '%s\n' "$line"
  done
  exec {target_guard_read_fd}<&-
  target_guard_read_fd=""
  wait "$target_guard_pid" || guard_status=$?
  target_guard_held=false

  if (( guard_status != 0 )); then
    echo "Target deployment guard failed while restoring backup timers" >&2
    return 1
  fi
}

resume_backup_timers() {
  ssh "$remote_host" bash -s <<'RESUME_TIMERS'
set -euo pipefail
paused_timers_file="/run/nixos-apply-paused-backup-timers"

if [[ -f "$paused_timers_file" ]]; then
  timers=()
  while IFS= read -r timer; do
    [[ -n "$timer" ]] || continue
    timers+=("$timer")
  done < "$paused_timers_file"

  for timer in "${timers[@]}"; do
    dropin_dir="/run/systemd/system/${timer}.d"
    sudo rm -f "$dropin_dir/90-nixos-apply-guard.conf"
    sudo rmdir "$dropin_dir" 2>/dev/null || true
  done
  sudo systemctl daemon-reload

  valid_timers=()
  removed_timers=()
  for timer in "${timers[@]}"; do
    if systemctl cat "$timer" >/dev/null 2>&1; then
      valid_timers+=("$timer")
    else
      removed_timers+=("$timer")
    fi
  done
  if (( ${#valid_timers[@]} > 0 )); then
    sudo systemctl start "${valid_timers[@]}"
  fi

  inactive_timers=()
  remaining_dropins=()
  for timer in "${valid_timers[@]}"; do
    systemctl is-active --quiet "$timer" || inactive_timers+=("$timer")
    if [[ -e "/run/systemd/system/${timer}.d/90-nixos-apply-guard.conf" ]]; then
      remaining_dropins+=("$timer")
    fi
  done

  if (( ${#inactive_timers[@]} > 0 || ${#remaining_dropins[@]} > 0 )); then
    printf 'Legacy backup timer restoration failed: recorded=%d valid=%d inactive=%d remaining_dropins=%d removed=%d\n' \
      "${#timers[@]}" "${#valid_timers[@]}" "${#inactive_timers[@]}" \
      "${#remaining_dropins[@]}" "${#removed_timers[@]}" >&2
    printf '%s\n' "${inactive_timers[@]}" >&2
    exit 1
  fi

  sudo rm -f "$paused_timers_file"
  printf 'Legacy backup timers restored: recorded=%d active=%d removed=%d dropins=0\n' \
    "${#timers[@]}" "${#valid_timers[@]}" "${#removed_timers[@]}"
fi
RESUME_TIMERS
}

pause_backup_timers() {
  ssh "$remote_host" bash -s <<'PAUSE_TIMERS'
set -euo pipefail
paused_timers_file="/run/nixos-apply-paused-backup-timers"
timer_list=$(
  systemctl list-units --type=timer --state=active --no-pager --no-legend \
    | awk '{ print $1 }' \
    | grep -E '^(restic-backups?-|pgbackrest-|syncoid-|sanoid\.timer)' \
    | sort -u \
    || true
)

printf '%s\n' "$timer_list" | sed '/^$/d' | sudo tee "$paused_timers_file" >/dev/null
timers=()
while IFS= read -r timer; do
  [[ -n "$timer" ]] || continue
  timers+=("$timer")
done < "$paused_timers_file"
if (( ${#timers[@]} > 0 )); then
  for timer in "${timers[@]}"; do
    dropin_dir="/run/systemd/system/${timer}.d"
    sudo install -d -m 0755 "$dropin_dir"
    printf '[Unit]\nConditionPathExists=!%s\n' "$paused_timers_file" \
      | sudo tee "$dropin_dir/90-nixos-apply-guard.conf" >/dev/null
  done
  sudo systemctl daemon-reload
  sudo systemctl stop "${timers[@]}"
fi

backup_unit_pattern='^(restic-backups?-|pgbackrest-.*backup|syncoid-|sanoid\.service)'

failed_jobs=$(
  systemctl list-units --type=service --state=failed --no-pager --no-legend --plain \
    | awk '{ print $1 }' \
    | grep -E "$backup_unit_pattern" \
    | sort -u \
    || true
)
if [[ -n "$failed_jobs" ]]; then
  printf 'Refusing deployment; backup jobs are failed after timer quiescence:\n%s\n' "$failed_jobs" >&2
  exit 1
fi

active_jobs=$(
  {
    systemctl list-units --type=service --all --no-pager --no-legend --plain \
      | awk '$3 == "activating" || $3 == "deactivating" || $4 == "running" { print $1 }'
    systemctl list-jobs --no-pager --no-legend \
      | awk '$3 == "start" { print $2 }'
  } \
    | grep -E "$backup_unit_pattern" \
    | sort -u \
    || true
)

if [[ -n "$active_jobs" ]]; then
  printf 'Waiting for in-flight backup jobs after timer quiescence:\n%s\n' "$active_jobs"
  after_units=$(printf '%s ' $active_jobs)
  sudo systemd-run \
    --quiet \
    --wait \
    --collect \
    --unit="nixos-apply-backup-drain-$$" \
    --property="After=$after_units" \
    /run/current-system/sw/bin/true
fi

remaining_jobs=$(
  systemctl list-units --type=service --all --no-pager --no-legend --plain \
    | awk '$3 == "activating" || $3 == "deactivating" || $3 == "failed" || $4 == "running" { print $1 }' \
    | grep -E "$backup_unit_pattern" \
    | sort -u \
    || true
)
if [[ -n "$remaining_jobs" ]]; then
  printf 'Refusing deployment; backup jobs did not drain cleanly:\n%s\n' "$remaining_jobs" >&2
  exit 1
fi

timer_count=$(wc -l < "$paused_timers_file" | tr -d ' ')
printf 'Paused %s backup timers\n' "$timer_count"
PAUSE_TIMERS
}

# Invoked indirectly through the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  local cleanup_status=$?
  trap - EXIT

  if [[ "$target_guard_held" == true ]]; then
    if ! release_target_guard; then
      echo "Failed to release target deployment guard on $remote_host" >&2
      cleanup_status=1
    fi
  elif [[ "$legacy_timers_paused" == true ]]; then
    if ! resume_backup_timers; then
      echo "Failed to restore backup timers on $remote_host" >&2
      cleanup_status=1
    fi
  fi

  rm -f "$rebuild_log"
  exit "$cleanup_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Prefer a target-owned lease. The legacy path exists only to bootstrap a host
# whose current generation predates nixos-deploy-backup-guard.
if target_guard_is_available; then
  target_guard_available=true
  if ! recover_target_guard; then
    echo "Failed to recover abandoned target guard state before deployment" >&2
    exit 1
  fi
else
  echo "Target deployment guard is not installed; using the legacy bootstrap path" >&2
  legacy_timers_paused=true
  if ! resume_backup_timers; then
    echo "Failed to recover backup timers before deployment" >&2
    exit 1
  fi
  legacy_timers_paused=false
fi

if ! reset_transient_units false; then
  echo "Failed to clear stale transient Podman healthcheck units" >&2
  exit 1
fi

if [[ "$target_guard_available" == true ]]; then
  if ! start_target_guard; then
    echo "Failed to acquire the target deployment backup lease" >&2
    exit 1
  fi
else
  legacy_timers_paused=true
  if ! pause_backup_timers; then
    echo "Failed to quiesce backup timers before deployment" >&2
    exit 1
  fi
fi

printf -v rebuild_command \
  'nixos-rebuild switch --flake .#%q --fast --use-remote-sudo --build-host %q --target-host %q' \
  "$host" "$remote_host" "$remote_host"

rebuild_exit=0
nix-shell -p nixos-rebuild --run "$rebuild_command" 2>&1 | tee "$rebuild_log"
rebuild_exit=${PIPESTATUS[0]}

if [[ "$target_guard_available" == true ]]; then
  if ! release_target_guard; then
    echo "Failed to restore backup timers through the target deployment guard" >&2
    exit 1
  fi
else
  if ! resume_backup_timers; then
    echo "Failed to restore backup timers after deployment" >&2
    exit 1
  fi
  legacy_timers_paused=false
fi

if (( rebuild_exit == 0 )); then
  exit 0
fi

if ! grep -q 'activating the configuration' "$rebuild_log"; then
  echo "nixos-rebuild failed during the build phase" >&2
  grep -E 'error:|manifest is not valid|sops-install-secrets|SC[0-9]+' "$rebuild_log" \
    | tail -10 \
    | sed 's/^/  /' \
    || true
  exit "$rebuild_exit"
fi

all_failed=$(
  ssh "$remote_host" \
    'systemctl --failed --no-pager --no-legend --plain --state=failed' 2>/dev/null \
    | awk '{ print $1 }' \
    || true
)
real_failures=$(
  printf '%s\n' "$all_failed" \
    | grep -vE '^[0-9a-f]{64}(-startup)?-[0-9a-f]+\.service$' \
    | grep -vE '^$' \
    || true
)

if [[ -n "$all_failed" && -z "$real_failures" ]]; then
  filtered_count=$(printf '%s\n' "$all_failed" | grep -cE '^[0-9a-f]{64}' || true)
  if ! reset_transient_units true; then
    echo "Transient Podman healthcheck failures have unhealthy owners" >&2
    exit "$rebuild_exit"
  fi
  printf 'nixos-rebuild reported only %s transient Podman healthcheck failure(s); treating activation as successful\n' "$filtered_count"
  exit 0
fi

if [[ -n "$real_failures" ]]; then
  echo "nixos-rebuild failed and these non-transient units are failed:" >&2
  printf '%s\n' "$real_failures" >&2
else
  echo "nixos-rebuild failed after activation without a classified failed unit" >&2
fi
exit "$rebuild_exit"
