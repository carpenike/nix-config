#!/usr/bin/env bash
# Write node_exporter textfile metrics for Sanoid autosnap datasets.
#
# A missing dataset used to be counted with grep -c, which prints 0 and exits
# 1 when nothing matches. A fallback echo then appended a second 0. The
# textfile contained a stray line, node_exporter rejected the whole file
# ("invalid metric name"), and every dataset's snapshot series disappeared.
# Capture exactly one integer, and publish only after the file parses. A
# dataset that cannot be listed is a single zfs_snapshot_dataset_missing
# sample; its count, age, and space series are omitted.

# shellcheck shell=bash

set -euo pipefail

usage() {
  echo "usage: $0 [--metrics-file PATH] -- DATASET..." >&2
  exit 2
}

# Prometheus label-value escaping (\ -> \\, " -> \", newline -> \n).
prom_escape() {
  local s=$1
  local out="" char i
  local backslash=$'\\'
  local quote='"'
  local newline=$'\n'
  for ((i = 0; i < ${#s}; i++)); do
    char=${s:i:1}
    case "$char" in
      "$backslash") out+="$backslash$backslash" ;;
      "$quote") out+="$backslash$quote" ;;
      "$newline") out+="${backslash}n" ;;
      *) out+="$char" ;;
    esac
  done
  printf '%s' "$out"
}

# Print exactly one non-negative integer, or return 1. Rejects a two-line
# capture such as the stray 0 the old count fallback appended.
one_integer() {
  local raw=$1
  local value
  if ! value=$(printf '%s\n' "$raw" | awk '
    BEGIN { lines = 0 }
    NF { lines++; v = $1 }
    END {
      if (lines != 1 || v !~ /^[0-9]+$/) exit 1
      print v
    }
  '); then
    printf 'zfs-snapshot-metrics: value is not a single integer: %q\n' "$raw" >&2
    return 1
  fi
  printf '%s' "$value"
}

# Series for a dataset that zfs list was able to open. Stdout is the samples.
# A value that is not one integer is a failure so the caller can emit the
# missing signal instead of a partial or malformed block.
emit_present() {
  local dataset=$1
  local escaped snapshot_names snapshot_count latest_name latest_timestamp total_used
  escaped=$(prom_escape "$dataset")

  # No snapshots is a successful empty list (zfs exits 1, "no datasets
  # available"). Do not append another number on that failure.
  snapshot_names=$(zfs list -H -t snapshot -o name -r "$dataset" 2>/dev/null || true)
  snapshot_count=$(
    printf '%s\n' "$snapshot_names" | SNAPSHOT_DATASET=$dataset awk '
      BEGIN { n = 0 }
      index($0, ENVIRON["SNAPSHOT_DATASET"] "@") == 1 { n++ }
      END { print n + 0 }
    '
  )
  snapshot_count=$(one_integer "$snapshot_count") || return 1

  # -s creation is ascending, so the last line is the newest snapshot of this
  # dataset. Children are not included (no -r), matching the previous query.
  latest_name=$(zfs list -H -t snapshot -o name -s creation "$dataset" 2>/dev/null | tail -n 1 || true)
  latest_timestamp=""
  if [[ -n "$latest_name" ]]; then
    latest_timestamp=$(zfs get -H -p -o value creation "$latest_name" 2>/dev/null || true)
    latest_timestamp=$(one_integer "$latest_timestamp") || return 1
  fi

  # -r includes child datasets, as the previous used-bytes sum did.
  # awk prints one integer even when zfs exits 1 with no rows.
  total_used=$(
    zfs list -Hp -t snapshot -o used -r "$dataset" 2>/dev/null | awk '
      BEGIN { sum = 0 }
      { sum += $1 }
      END { print sum + 0 }
    ' || true
  )
  total_used=$(one_integer "$total_used") || return 1

  printf 'zfs_snapshot_dataset_info{dataset="%s"} 1\n' "$escaped"
  printf 'zfs_snapshot_count{dataset="%s"} %s\n' "$escaped" "$snapshot_count"
  if [[ -n "$latest_timestamp" ]]; then
    printf 'zfs_snapshot_latest_timestamp{dataset="%s"} %s\n' "$escaped" "$latest_timestamp"
  fi
  printf 'zfs_snapshot_total_used_bytes{dataset="%s"} %s\n' "$escaped" "$total_used"
}

# Every non-comment line must be one sample. This is the backstop when
# promtool is not installed; promtool is still preferred when it is.
validate_metrics() {
  local file=$1
  awk '
    BEGIN { bad = 0 }
    /^[[:space:]]*($|#)/ { next }
    /^[a-zA-Z_:][a-zA-Z0-9_:]*(\{[^{}]*\})?[ \t]+[0-9]+[ \t]*$/ { next }
    {
      printf "zfs-snapshot-metrics: invalid metric line: %s\n", $0 > "/dev/stderr"
      bad = 1
    }
    END { exit bad ? 1 : 0 }
  ' "$file"
}

main() {
  export LC_ALL=C
  local metrics_file=/var/lib/node_exporter/textfile_collector/zfs_snapshots.prom

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --metrics-file)
        [[ $# -ge 2 ]] || usage
        metrics_file=$2
        shift 2
        ;;
      --)
        shift
        break
        ;;
      -*)
        usage
        ;;
      *)
        break
        ;;
    esac
  done

  local -a datasets=("$@")
  if [[ ${#datasets[@]} -eq 0 ]]; then
    echo "zfs-snapshot-metrics: no datasets given; keeping ${metrics_file}" >&2
    exit 1
  fi

  local metrics_dir tmp lint
  metrics_dir=$(dirname -- "$metrics_file")
  mkdir -p -- "$metrics_dir"
  tmp=$(mktemp "${metrics_file}.XXXXXX")
  lint=$(mktemp "${metrics_file}.lint.XXXXXX")
  cleanup() {
    rm -f -- "$tmp" "$lint"
  }
  trap cleanup EXIT

  cat >"$tmp" <<'EOF'
# HELP zfs_snapshot_dataset_info 1 when a Sanoid dataset exists and its snapshot series are reported
# TYPE zfs_snapshot_dataset_info gauge
# HELP zfs_snapshot_dataset_missing 1 when a declared Sanoid dataset is missing or unreadable
# TYPE zfs_snapshot_dataset_missing gauge
# HELP zfs_snapshot_count Number of snapshots per dataset
# TYPE zfs_snapshot_count gauge
# HELP zfs_snapshot_latest_timestamp Creation time of most recent snapshot per dataset (Unix timestamp)
# TYPE zfs_snapshot_latest_timestamp gauge
# HELP zfs_snapshot_total_used_bytes Total space used by all snapshots for a dataset
# TYPE zfs_snapshot_total_used_bytes gauge
EOF

  local dataset series escaped
  for dataset in "${datasets[@]}"; do
    escaped=$(prom_escape "$dataset")
    if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
      echo "zfs-snapshot-metrics: dataset missing or unreadable: ${dataset}" >&2
      printf 'zfs_snapshot_dataset_missing{dataset="%s"} 1\n' "$escaped" >>"$tmp"
      continue
    fi
    if ! series=$(emit_present "$dataset"); then
      echo "zfs-snapshot-metrics: omitting dataset with unreadable snapshot metrics: ${dataset}" >&2
      printf 'zfs_snapshot_dataset_missing{dataset="%s"} 1\n' "$escaped" >>"$tmp"
      continue
    fi
    printf '%s\n' "$series" >>"$tmp"
  done

  # Test seam: append a raw line so the pre-publish check can be forced to fail.
  if [[ -n "${ZFS_SNAPSHOT_METRICS_INJECT:-}" ]]; then
    printf '%s\n' "$ZFS_SNAPSHOT_METRICS_INJECT" >>"$tmp"
  fi

  if ! validate_metrics "$tmp"; then
    echo "zfs-snapshot-metrics: refusing to publish malformed metrics; keeping ${metrics_file}" >&2
    exit 1
  fi

  local promtool_bin=""
  if [[ -n "${PROMTOOL:-}" ]]; then
    promtool_bin=$PROMTOOL
  elif command -v promtool >/dev/null 2>&1; then
    promtool_bin=$(command -v promtool)
  fi

  if [[ -n "$promtool_bin" ]]; then
    local lint_status=0
    "$promtool_bin" check metrics <"$tmp" >"$lint" 2>&1 || lint_status=$?
    case "$lint_status" in
      0 | 3) ;;
      *)
        echo "zfs-snapshot-metrics: promtool check metrics failed (exit ${lint_status}); keeping ${metrics_file}" >&2
        cat "$lint" >&2
        exit 1
        ;;
    esac
  fi

  mv -f -- "$tmp" "$metrics_file"
  chmod 644 -- "$metrics_file"
  rm -f -- "$lint"
  trap - EXIT
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
