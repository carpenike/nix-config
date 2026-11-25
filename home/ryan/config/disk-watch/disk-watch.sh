# shellcheck shell=bash
# disk-watch: hourly free-space and hotspot-growth monitor for rymac.
#
# Read-only by design: it measures and alerts, it never deletes anything.
#
# Usage:
#   disk-watch [run]       one check (what the launchd agent runs every hour)
#   disk-watch status      print free space, recent samples and hotspot sizes
#   disk-watch test        send a test toast (and a Pushover message if configured)
#
# Configuration comes from the environment (set by the home-manager module):
#   DW_VOLUME              volume to watch (default /System/Volumes/Data)
#   DW_WARN_GB / DW_CRIT_GB    free-space thresholds
#   DW_DROP_GB             alert when free space falls by more than this in 24 h
#   DW_GROWTH_GB           alert when one hotspot grows by more than this in 7 days
#   DW_HOTSPOTS            newline-separated "label|path" entries; a path may be a glob,
#                          and @usertmp@ expands to the per-user /var/folders directory
#   DW_PUSHOVER_TOKEN_FILE / DW_PUSHOVER_USER_FILE   optional; critical alerts only
#   DW_STATE_DIR           state directory

set -euo pipefail

volume="${DW_VOLUME:-/System/Volumes/Data}"
warn_gb="${DW_WARN_GB:-50}"
crit_gb="${DW_CRIT_GB:-20}"
drop_gb="${DW_DROP_GB:-15}"
growth_gb="${DW_GROWTH_GB:-10}"
state_dir="${DW_STATE_DIR:-$HOME/Library/Application Support/disk-watch}"
hotspots="${DW_HOTSPOTS:-}"

samples="$state_dir/free.tsv"       # epoch <TAB> free KiB
sizes="$state_dir/hotspots.tsv"     # epoch <TAB> label <TAB> KiB
alerted="$state_dir/alerted.tsv"    # key <TAB> YYYY-MM-DD
log="$state_dir/disk-watch.log"

kib_per_gb=$((1024 * 1024))
now="$(date +%s)"
today="$(date +%F)"

mkdir -p "$state_dir"
touch "$samples" "$sizes" "$alerted"

say() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$log"; }

gb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'; }

free_kib() { df -k "$volume" | awk 'NR == 2 { print $4 }'; }

toast() {
  # $1 title, $2 message. The terminal-notifier app's notification style decides
  # whether this stays on screen (set it to "Alerts" in System Settings).
  terminal-notifier -title "$1" -message "$2" -group "disk-watch-$1" \
    -sound default -execute "open -a 'Activity Monitor'" >/dev/null 2>&1 ||
    say "toast failed: $1"
}

pushover() {
  local token_file="${DW_PUSHOVER_TOKEN_FILE:-}" user_file="${DW_PUSHOVER_USER_FILE:-}"
  if [[ -z "$token_file" || ! -r "$token_file" || -z "$user_file" || ! -r "$user_file" ]]; then
    say "pushover not configured; toast only"
    return 0
  fi
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    --form-string "token=$(<"$token_file")" \
    --form-string "user=$(<"$user_file")" \
    --form-string "title=$1" \
    --form-string "message=$2" \
    --form-string "priority=1" \
    https://api.pushover.net/1/messages.json || echo 000)"
  [[ "$code" == 200 ]] || say "pushover failed: HTTP $code"
}

# Alert at most once per key per day.
alert() {
  local key="$1" level="$2" title="$3" message="$4"
  if grep -qxF "$key"$'\t'"$today" "$alerted"; then
    return 0
  fi
  say "ALERT [$level] $title: $message"
  toast "$title" "$message"
  if [[ "$level" == critical ]]; then
    pushover "$title" "$message"
  fi
  { grep -v "^$key"$'\t' "$alerted" || true; printf '%s\t%s\n' "$key" "$today"; } >"$alerted.tmp"
  mv "$alerted.tmp" "$alerted"
}

measure_hotspots() {
  local line label pattern path total kib
  # Split globs on newlines only, so paths with spaces stay whole.
  local IFS=$'\n'
  while read -r line; do
    [[ -z "$line" ]] && continue
    label="${line%%|*}"
    pattern="${line#*|}"
    # @usertmp@ is the per-user /var/folders/.../<id> directory (holds T, C and X).
    pattern="${pattern//@usertmp@/$(dirname "$(getconf DARWIN_USER_TEMP_DIR)")}"
    total=0
    # Unquoted on purpose: a hotspot path may be a glob (e.g. ~/src/*/.claude/worktrees).
    # shellcheck disable=SC2086
    for path in $pattern; do
      [[ -e "$path" ]] || continue
      # du exits non-zero on any unreadable entry; keep the partial total.
      kib="$({ du -skx "$path" 2>/dev/null || true; } | awk '{ print $1 }')"
      total=$((total + ${kib:-0}))
    done
    printf '%s\t%s\t%s\n' "$now" "$label" "$total" >>"$sizes"
  done <<<"$hotspots"
}

check() {
  local free
  free="$(free_kib)"
  printf '%s\t%s\n' "$now" "$free" >>"$samples"
  # Keep 30 days of hourly samples.
  awk -v cutoff=$((now - 30 * 86400)) '$1 >= cutoff' "$samples" >"$samples.tmp" && mv "$samples.tmp" "$samples"

  local free_gb
  free_gb="$(gb "$free")"
  say "free ${free_gb} GB"

  # Absolute thresholds.
  if ((free < crit_gb * kib_per_gb)); then
    alert free-critical critical "Disk critically low" "Only ${free_gb} GB free on this Mac (below ${crit_gb} GB)."
  elif ((free < warn_gb * kib_per_gb)); then
    alert free-warning warning "Disk space low" "${free_gb} GB free on this Mac (below ${warn_gb} GB)."
  fi

  # Sudden drop: compare with the oldest sample from the last 24-25 hours.
  local then_free
  then_free="$(awk -v lo=$((now - 25 * 3600)) -v hi=$((now - 23 * 3600)) \
    '$1 >= lo && $1 <= hi { print $2; exit }' "$samples")"
  if [[ -n "$then_free" ]] && ((then_free - free > drop_gb * kib_per_gb)); then
    alert free-drop warning "Disk filling fast" \
      "Free space fell $(gb $((then_free - free))) GB in the last day (now ${free_gb} GB)."
  fi

  # Hotspots: measure at most once every 20 hours (du is slow on big trees).
  local last
  last="$(awk 'END { print $1 }' "$sizes")"
  if [[ -n "$hotspots" ]] && { [[ -z "$last" ]] || ((now - last > 20 * 3600)); }; then
    measure_hotspots
    awk -v cutoff=$((now - 60 * 86400)) -F '\t' '$1 >= cutoff' "$sizes" >"$sizes.tmp" && mv "$sizes.tmp" "$sizes"
    check_growth
  fi
}

check_growth() {
  # For each label, compare the newest size with the newest one at least 7 days old.
  local label now_kib old_kib grew
  while IFS=$'\t' read -r label now_kib old_kib; do
    [[ -z "$old_kib" ]] && continue
    grew=$((now_kib - old_kib))
    if ((grew > growth_gb * kib_per_gb)); then
      alert "growth-$label" warning "$label is growing" \
        "$label grew $(gb "$grew") GB in a week (now $(gb "$now_kib") GB)."
    fi
  done < <(awk -F '\t' -v week=$((now - 7 * 86400)) '
    { latest[$2] = $3 }
    $1 <= week { old[$2] = $3 }
    END { for (l in latest) print l "\t" latest[l] "\t" old[l] }' "$sizes")
}

status() {
  echo "Volume: $volume"
  echo "Free now: $(gb "$(free_kib)") GB (warn < ${warn_gb}, critical < ${crit_gb})"
  echo
  if [[ -s "$sizes" ]]; then
    echo "Hotspots (measured $(date -d "@$(awk 'END { print $1 }' "$sizes")" '+%F %T')):"
    awk -F '\t' '{ latest[$2] = $3 } END {
        for (l in latest) printf "%10.1f GB  %s\n", latest[l] / 1048576, l
      }' "$sizes" | sort -rn
  else
    echo "Hotspots: not measured yet"
  fi
  echo
  echo "Alerts sent (last date per kind):"
  sed 's/^/  /' "$alerted"
  echo
  echo "Log: $log"
}

case "${1:-run}" in
  run) check ;;
  status) status ;;
  test)
    toast "disk-watch test" "Toast delivery works. Free: $(gb "$(free_kib)") GB."
    pushover "disk-watch test" "Pushover delivery works. Free: $(gb "$(free_kib)") GB."
    ;;
  *)
    echo "usage: disk-watch [run|status|test]" >&2
    exit 2
    ;;
esac
