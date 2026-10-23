#!/usr/bin/env bash
# Write node_exporter textfile metrics for Sanoid autosnap datasets.
#
# A missing dataset used to be counted with grep -c, which prints 0 and exits
# 1 when nothing matches. A fallback echo then appended a second 0. The used
# sum had the same shape: awk prints an empty line when zfs returns no rows,
# then the fallback echo adds a bare 0. The textfile contained a stray line,
# node_exporter rejected the whole file ("invalid metric name"), and every
# dataset's snapshot series disappeared.
#
# Filesystems and snapshots are listed once. Count, newest creation, and
# recursive snapshot usage (child snapshots roll up to ancestors, matching
# `zfs list -t snapshot -o used -r`) are integers from that table. A dataset
# with zero snapshots gets count 0, used 0, and no latest-timestamp sample, so
# the age alerts do not see a fake epoch-0 creation. A dataset that is not in
# the filesystem list is not given those series. A failing zfs list keeps the
# previous file.

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

# List filesystems and snapshots once. A pool with no snapshots exits 1 and
# prints "no datasets available"; that is an empty table, not a failed read.
# Any other zfs failure returns 1 so the previous metrics file stays in place.
read_zfs_lists() {
  local fs_file=$1
  local snap_file=$2
  local err_file=$3
  local err_text=""
  local snap_status=0

  if ! zfs list -H -o name -t filesystem,volume >"$fs_file" 2>"$err_file"; then
    echo "zfs-snapshot-metrics: zfs list failed; keeping previous metrics" >&2
    cat "$err_file" >&2
    return 1
  fi

  zfs list -H -p -t snapshot -o name,creation,used >"$snap_file" 2>"$err_file" || snap_status=$?
  if [[ "$snap_status" -ne 0 ]]; then
    err_text=$(cat "$err_file")
    if [[ ! -s "$snap_file" && "$err_text" == *"no datasets available"* ]]; then
      : >"$snap_file"
      return 0
    fi
    echo "zfs-snapshot-metrics: zfs list snapshots failed; keeping previous metrics" >&2
    printf '%s\n' "$err_text" >&2
    return 1
  fi
}

# gawk (the unit's awk). One summary row per requested dataset:
#   ok|missing|bad, count, latest|- , used, dataset
summarize_snapshots() {
  local datasets_file=$1
  local fs_file=$2
  local snap_file=$3
  awk '
    ARGIND == 1 {
      if ($0 != "") {
        n++
        ds[n] = $0
        wanted[$0] = 1
      }
      next
    }
    ARGIND == 2 {
      if ($0 != "") exists[$0] = 1
      next
    }
    ARGIND == 3 {
      if ($0 == "") next
      split($0, f, "\t")
      if (f[1] == "") next
      at = index(f[1], "@")
      if (at == 0) next
      d = substr(f[1], 1, at - 1)
      creation = f[2]
      bytes = f[3]
      if (creation ~ /^[0-9]+$/) {
        count[d]++
        if (!(d in latest) || creation + 0 > latest[d] + 0) latest[d] = creation
      } else {
        bad[d] = 1
      }
      p = d
      if (bytes ~ /^[0-9]+$/) {
        while (p != "") {
          used[p] += bytes
          if (!sub(/\/[^\/]*$/, "", p)) break
        }
      } else {
        while (p != "") {
          bad[p] = 1
          if (!sub(/\/[^\/]*$/, "", p)) break
        }
      }
      next
    }
    END {
      for (i = 1; i <= n; i++) {
        name = ds[i]
        if (!(name in exists)) {
          printf "missing\t0\t-\t0\t%s\n", name
        } else if (name in bad) {
          printf "bad\t0\t-\t0\t%s\n", name
        } else {
          if (name in latest) ts = latest[name]
          else ts = "-"
          printf "ok\t%d\t%s\t%d\t%s\n", count[name] + 0, ts, used[name] + 0, name
        }
      }
    }
  ' "$datasets_file" "$fs_file" "$snap_file"
}

# Stdout is the samples for one summary row.
emit_summary_line() {
  local state=$1
  local count=$2
  local latest=$3
  local used=$4
  local dataset=$5
  local escaped
  escaped=$(prom_escape "$dataset")
  case "$state" in
    missing)
      echo "zfs-snapshot-metrics: dataset missing or unreadable: ${dataset}" >&2
      printf 'zfs_snapshot_dataset_exists{dataset="%s"} 0\n' "$escaped"
      printf 'zfs_snapshot_dataset_missing{dataset="%s"} 1\n' "$escaped"
      ;;
    bad)
      echo "zfs-snapshot-metrics: omitting dataset with unreadable snapshot metrics: ${dataset}" >&2
      printf 'zfs_snapshot_dataset_exists{dataset="%s"} 1\n' "$escaped"
      printf 'zfs_snapshot_dataset_missing{dataset="%s"} 1\n' "$escaped"
      ;;
    ok)
      count=$(one_integer "$count") || return 1
      used=$(one_integer "$used") || return 1
      printf 'zfs_snapshot_dataset_exists{dataset="%s"} 1\n' "$escaped"
      printf 'zfs_snapshot_dataset_info{dataset="%s"} 1\n' "$escaped"
      printf 'zfs_snapshot_count{dataset="%s"} %s\n' "$escaped" "$count"
      if [[ "$latest" != "-" ]]; then
        latest=$(one_integer "$latest") || return 1
        printf 'zfs_snapshot_latest_timestamp{dataset="%s"} %s\n' "$escaped" "$latest"
      fi
      printf 'zfs_snapshot_total_used_bytes{dataset="%s"} %s\n' "$escaped" "$used"
      ;;
    *)
      echo "zfs-snapshot-metrics: bad summary state for ${dataset}: ${state}" >&2
      return 1
      ;;
  esac
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

  local metrics_dir tmp lint datasets_file fs_file snap_file summary_file list_err
  local summary_rows state count latest used dataset
  metrics_dir=$(dirname -- "$metrics_file")
  mkdir -p -- "$metrics_dir"
  tmp=$(mktemp "${metrics_file}.XXXXXX")
  lint=$(mktemp "${metrics_file}.lint.XXXXXX")
  datasets_file=$(mktemp "${metrics_file}.datasets.XXXXXX")
  fs_file=$(mktemp "${metrics_file}.fs.XXXXXX")
  snap_file=$(mktemp "${metrics_file}.snaps.XXXXXX")
  summary_file=$(mktemp "${metrics_file}.summary.XXXXXX")
  list_err=$(mktemp "${metrics_file}.zerr.XXXXXX")
  cleanup() {
    rm -f -- "$tmp" "$lint" "$datasets_file" "$fs_file" "$snap_file" "$summary_file" "$list_err"
  }
  trap cleanup EXIT

  printf '%s\n' "${datasets[@]}" >"$datasets_file"
  read_zfs_lists "$fs_file" "$snap_file" "$list_err"
  summarize_snapshots "$datasets_file" "$fs_file" "$snap_file" >"$summary_file"
  summary_rows=$(wc -l <"$summary_file")
  summary_rows=$((summary_rows))
  if [[ "$summary_rows" -ne ${#datasets[@]} ]]; then
    echo "zfs-snapshot-metrics: expected ${#datasets[@]} summary rows, got ${summary_rows}; keeping ${metrics_file}" >&2
    exit 1
  fi

  cat >"$tmp" <<'EOF'
# HELP zfs_snapshot_dataset_info 1 when a Sanoid dataset exists and its snapshot series are reported
# TYPE zfs_snapshot_dataset_info gauge
# HELP zfs_snapshot_dataset_exists 1 when a configured Sanoid dataset exists in the pool
# TYPE zfs_snapshot_dataset_exists gauge
# HELP zfs_snapshot_dataset_missing 1 when a declared Sanoid dataset is missing or its snapshot rows were unreadable
# TYPE zfs_snapshot_dataset_missing gauge
# HELP zfs_snapshot_count Number of snapshots per dataset
# TYPE zfs_snapshot_count gauge
# HELP zfs_snapshot_latest_timestamp Creation time of most recent snapshot per dataset (Unix timestamp)
# TYPE zfs_snapshot_latest_timestamp gauge
# HELP zfs_snapshot_total_used_bytes Total space used by all snapshots for a dataset
# TYPE zfs_snapshot_total_used_bytes gauge
EOF

  while IFS=$'\t' read -r state count latest used dataset; do
    [[ -n "$state" ]] || continue
    emit_summary_line "$state" "$count" "$latest" "$used" "$dataset"
  done <"$summary_file" >>"$tmp"

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

  # mktemp is mode 0600. Make the file readable before the rename so the
  # published inode is 0644 with no window where node_exporter cannot read it.
  chmod 644 -- "$tmp"
  mv -f -- "$tmp" "$metrics_file"
  # The published file used to be $tmp. Remove the list temps explicitly so a
  # cleared EXIT trap cannot leave them beside the textfile collector.
  cleanup
  trap - EXIT
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
