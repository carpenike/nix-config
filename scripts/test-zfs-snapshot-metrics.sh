#!/usr/bin/env bash
# Run zfs-snapshot-metrics.sh against a fake zfs, including a missing dataset.
# The historical failure is grep -c printing 0 and `|| echo 0` appending
# another 0, which node_exporter rejects as a metric name.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <zfs-snapshot-metrics.sh>" >&2
  exit 2
fi

script=$1
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_line() {
  local line=$1
  local file=$2
  grep -Fxq -- "$line" "$file" || fail "missing line in ${file}: ${line}"
}

assert_absent() {
  local needle=$1
  local file=$2
  if grep -F -- "$needle" "$file" >/dev/null; then
    fail "unexpected line matching ${needle} in ${file}"
  fi
}

# promtool exits 3 for lint. zfs_snapshot_count keeps its existing name, so the
# "_count suffix" lint is expected and is not a parse failure.
check_metrics() {
  local file=$1
  local status=0
  local output
  output=$("$real_promtool" check metrics <"$file" 2>&1) || status=$?
  case "$status" in
    0 | 3) ;;
    *)
      printf '%s\n' "$output" >&2
      fail "promtool check metrics exited ${status} for ${file}"
      ;;
  esac
}

# The bug, isolated: grep -c writes 0 and exits 1, so the echo runs too.
historical=$(printf '' | grep -c '^tank/services/openproject@' || echo 0)
if [[ "$historical" != $'0\n0' ]]; then
  fail "expected the historical grep -c || echo 0 capture to be two zeros, got $(printf '%q' "$historical")"
fi

if grep -vE '^[[:space:]]*#' "$script" | grep -nE '\|\| *echo'; then
  fail "script still appends a fallback echo after a pipeline"
fi

# pre-commit runs shellcheck per file and does not pass -x, so it will not
# follow this source. The directive still documents the file for a manual -x run.
# shellcheck disable=SC1091
# shellcheck source=scripts/zfs-snapshot-metrics.sh
source "$script"

[[ $(prom_escape 'a"b') == 'a\"b' ]] || fail "quote escape"
[[ $(prom_escape 'a\b') == 'a\\b' ]] || fail "backslash escape"
[[ $(prom_escape $'a\nb') == 'a\nb' ]] || fail "newline escape"
[[ $(one_integer 0) == 0 ]] || fail "zero integer"
[[ $(one_integer 12) == 12 ]] || fail "integer"
if one_integer $'0\n0' >/dev/null 2>&1; then
  fail "one_integer accepted the stray-zero capture"
fi
if one_integer '' >/dev/null 2>&1; then
  fail "one_integer accepted an empty capture"
fi

fake_bin=$root/bin
mkdir -p "$fake_bin"
# Absolute shebang: the Nix sandbox has no /usr/bin/env.
printf '#!%s\n' "$(command -v bash)" >"$fake_bin/zfs"
cat >>"$fake_bin/zfs" <<'FAKE'
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "fake zfs: expected a list command" >&2
  exit 2
fi

cmd=$1
shift
joined=""
printf -v joined ' %s ' "$@"

if [[ "$cmd" != "list" ]]; then
  echo "fake zfs: unhandled command: $cmd" >&2
  exit 2
fi

if [[ "$joined" == *" snapshot "* ]]; then
  if [[ -n "${ZFS_FAIL_SNAPSHOTS:-}" ]]; then
    echo "cannot list snapshots" >&2
    exit 1
  fi
  if [[ -n "${ZFS_NO_SNAPSHOTS:-}" ]]; then
    echo "no datasets available" >&2
    exit 1
  fi
  printf '%s\n' \
    $'tank/services/plex@autosnap_old\t1700000000\t100' \
    $'tank/services/plex/child@snap\t1700000500\t5' \
    $'tank/services/plex@autosnap_new\t1700001000\t250' \
    $'tank/services/badtime@autosnap_bad\tnope\t10'
  exit 0
fi

if [[ -n "${ZFS_FAIL_FILESYSTEMS:-}" ]]; then
  echo "cannot list filesystems" >&2
  exit 1
fi

printf '%s\n' \
  tank/services/plex \
  tank/services/plex/child \
  tank/services/empty \
  tank/services/badtime
FAKE
chmod 755 "$fake_bin/zfs"

real_promtool=$(command -v promtool)
[[ -n "$real_promtool" ]] || fail "promtool must be on PATH for this test"

export PATH="$fake_bin:$PATH"

metrics=$root/zfs_snapshots.prom
stderr=$root/stderr

run_metrics() {
  bash "$script" --metrics-file "$metrics" "$@"
}

run_metrics \
  tank/services/plex \
  tank/services/empty \
  tank/services/openproject \
  tank/services/unreadable \
  2>"$stderr"

check_metrics "$metrics"
[[ "$(stat -c %a "$metrics")" == "644" ]] || fail "published metrics file is not mode 644"

assert_line '# HELP zfs_snapshot_dataset_missing 1 when a declared Sanoid dataset is missing or its snapshot rows were unreadable' "$metrics"
assert_line '# TYPE zfs_snapshot_dataset_missing gauge' "$metrics"
assert_line '# HELP zfs_snapshot_dataset_exists 1 when a configured Sanoid dataset exists in the pool' "$metrics"
assert_line '# TYPE zfs_snapshot_dataset_exists gauge' "$metrics"
assert_line 'zfs_snapshot_dataset_exists{dataset="tank/services/plex"} 1' "$metrics"
assert_line 'zfs_snapshot_dataset_info{dataset="tank/services/plex"} 1' "$metrics"
assert_line 'zfs_snapshot_count{dataset="tank/services/plex"} 2' "$metrics"
assert_line 'zfs_snapshot_latest_timestamp{dataset="tank/services/plex"} 1700001000' "$metrics"
# Child snapshot used bytes roll up to the parent (100+250+5). Count does not.
assert_line 'zfs_snapshot_total_used_bytes{dataset="tank/services/plex"} 355' "$metrics"
assert_absent 'zfs_snapshot_dataset_missing{dataset="tank/services/plex"}' "$metrics"
assert_line 'zfs_snapshot_dataset_exists{dataset="tank/services/empty"} 1' "$metrics"
assert_line 'zfs_snapshot_dataset_info{dataset="tank/services/empty"} 1' "$metrics"
assert_line 'zfs_snapshot_count{dataset="tank/services/empty"} 0' "$metrics"
assert_line 'zfs_snapshot_total_used_bytes{dataset="tank/services/empty"} 0' "$metrics"
assert_absent 'zfs_snapshot_latest_timestamp{dataset="tank/services/empty"}' "$metrics"
assert_absent 'zfs_snapshot_dataset_missing{dataset="tank/services/empty"}' "$metrics"
assert_line 'zfs_snapshot_dataset_exists{dataset="tank/services/openproject"} 0' "$metrics"
assert_line 'zfs_snapshot_dataset_missing{dataset="tank/services/openproject"} 1' "$metrics"
assert_line 'zfs_snapshot_dataset_exists{dataset="tank/services/unreadable"} 0' "$metrics"
assert_line 'zfs_snapshot_dataset_missing{dataset="tank/services/unreadable"} 1' "$metrics"
assert_absent 'zfs_snapshot_count{dataset="tank/services/openproject"}' "$metrics"
assert_absent 'zfs_snapshot_dataset_info{dataset="tank/services/openproject"}' "$metrics"
assert_absent 'zfs_snapshot_total_used_bytes{dataset="tank/services/openproject"}' "$metrics"
assert_absent 'zfs_snapshot_latest_timestamp{dataset="tank/services/openproject"}' "$metrics"
assert_absent 'zfs_snapshot_count{dataset="tank/services/unreadable"}' "$metrics"
assert_absent 'dataset="tank/services/plex/child"' "$metrics"

if grep -Eq '^[0-9]+$' "$metrics"; then
  fail "bare number line in metrics file"
fi

grep -F 'dataset missing or unreadable: tank/services/openproject' "$stderr" >/dev/null \
  || fail "missing dataset was not logged"
grep -F 'dataset missing or unreadable: tank/services/unreadable' "$stderr" >/dev/null \
  || fail "unreadable dataset was not logged"

# One count line per readable dataset, none for the two that could not be listed.
count_lines=$(grep -c '^zfs_snapshot_count{' "$metrics")
[[ "$count_lines" -eq 2 ]] || fail "expected 2 count series, got ${count_lines}"

# A creation value that is not an integer must not publish a partial block.
bad_metrics=$root/bad.prom
bash "$script" --metrics-file "$bad_metrics" tank/services/badtime 2>"$root/bad.stderr"
check_metrics "$bad_metrics"
assert_line 'zfs_snapshot_dataset_exists{dataset="tank/services/badtime"} 1' "$bad_metrics"
assert_line 'zfs_snapshot_dataset_missing{dataset="tank/services/badtime"} 1' "$bad_metrics"
assert_absent 'zfs_snapshot_count{dataset="tank/services/badtime"}' "$bad_metrics"
assert_absent 'zfs_snapshot_dataset_info{dataset="tank/services/badtime"}' "$bad_metrics"
assert_absent 'zfs_snapshot_latest_timestamp{dataset="tank/services/badtime"}' "$bad_metrics"
grep -F 'omitting dataset with unreadable snapshot metrics: tank/services/badtime' "$root/bad.stderr" >/dev/null \
  || fail "bad timestamp was not logged"

# Malformed output keeps the previous file (regex check, before promtool).
printf 'zfs_sentinel 1\n' >"$metrics"
if ZFS_SNAPSHOT_METRICS_INJECT='0' bash "$script" --metrics-file "$metrics" tank/services/plex \
  >"$root/inject.stdout" 2>"$root/inject.stderr"; then
  fail "injected bare 0 was published"
fi
assert_line 'zfs_sentinel 1' "$metrics"
grep -F 'invalid metric line: 0' "$root/inject.stderr" >/dev/null || fail "regex check did not report the bare 0"
grep -F 'refusing to publish malformed metrics' "$root/inject.stderr" >/dev/null || fail "publish was not refused"
leaks=$(find "$root" -name 'zfs_snapshots.prom.*' -print)
if [[ -n "$leaks" ]]; then
  fail "temp metrics file leaked: ${leaks}"
fi

# promtool failure keeps the previous file even when the text is otherwise valid.
mkdir -p "$root/bad-promtool"
fake_promtool=$root/bad-promtool/promtool
printf '#!%s\n' "$(command -v bash)" >"$fake_promtool"
cat >>"$fake_promtool" <<'PROM'
echo "rejected on purpose" >&2
exit 1
PROM
chmod 755 "$fake_promtool"
if PROMTOOL=$fake_promtool bash "$script" --metrics-file "$metrics" tank/services/plex \
  >"$root/prom.stdout" 2>"$root/prom.stderr"; then
  fail "failing promtool was ignored"
fi
assert_line 'zfs_sentinel 1' "$metrics"
grep -F 'promtool check metrics failed' "$root/prom.stderr" >/dev/null || fail "promtool failure was not logged"
grep -F 'rejected on purpose' "$root/prom.stderr" >/dev/null || fail "promtool stderr was not logged"

# Without promtool, the line check still publishes a file promtool accepts.
# Symlink the tools the script needs so promtool's directory (often shared
# with coreutils on a distro PATH) is not required.
isolated=$root/isolated-bin
mkdir -p "$isolated"
ln -s "$fake_bin/zfs" "$isolated/zfs"
for tool in bash cat awk grep mktemp chmod mv mkdir dirname tail rm wc; do
  ln -s "$(command -v "$tool")" "$isolated/$tool"
done
noprom=$root/noprom.prom
PATH=$isolated bash "$script" --metrics-file "$noprom" \
  tank/services/plex tank/services/openproject \
  >"$root/noprom.stdout" 2>"$root/noprom.stderr"
if PATH=$isolated command -v promtool >/dev/null 2>&1; then
  fail "promtool was still visible"
fi
check_metrics "$noprom"
assert_line 'zfs_snapshot_count{dataset="tank/services/plex"} 2' "$noprom"
assert_line 'zfs_snapshot_dataset_missing{dataset="tank/services/openproject"} 1' "$noprom"
if grep -Eq '^[0-9]+$' "$noprom"; then
  fail "bare number line without promtool"
fi

# An empty dataset list must not replace a previous file with headers only.
printf 'zfs_sentinel 1\n' >"$metrics"
if bash "$script" --metrics-file "$metrics" -- >"$root/empty.stdout" 2>"$root/empty.stderr"; then
  fail "empty dataset list published"
fi
assert_line 'zfs_sentinel 1' "$metrics"
grep -F 'no datasets given' "$root/empty.stderr" >/dev/null || fail "empty dataset list was not logged"

# Production path: PROMTOOL is the absolute binary, ahead of PATH.
if ! PROMTOOL=$real_promtool bash "$script" --metrics-file "$metrics" tank/services/empty >/dev/null; then
  fail "absolute PROMTOOL path failed"
fi
check_metrics "$metrics"
assert_line 'zfs_snapshot_count{dataset="tank/services/empty"} 0' "$metrics"
assert_line 'zfs_snapshot_dataset_exists{dataset="tank/services/empty"} 1' "$metrics"
assert_absent 'zfs_snapshot_dataset_missing{dataset="tank/services/empty"}' "$metrics"
assert_absent 'zfs_snapshot_latest_timestamp{dataset="tank/services/empty"}' "$metrics"

# A pool with no snapshots is an empty table, not a failed zfs list.
# Every existing dataset is count 0 / used 0 and has no timestamp, so the age
# alerts cannot treat a fake 0 creation as ancient.
nosnap=$root/nosnap.prom
ZFS_NO_SNAPSHOTS=1 bash "$script" --metrics-file "$nosnap" \
  tank/services/plex tank/services/empty tank/services/openproject \
  >"$root/nosnap.stdout" 2>"$root/nosnap.stderr"
check_metrics "$nosnap"
assert_line 'zfs_snapshot_count{dataset="tank/services/plex"} 0' "$nosnap"
assert_line 'zfs_snapshot_total_used_bytes{dataset="tank/services/plex"} 0' "$nosnap"
assert_line 'zfs_snapshot_count{dataset="tank/services/empty"} 0' "$nosnap"
assert_absent 'zfs_snapshot_latest_timestamp{' "$nosnap"
assert_line 'zfs_snapshot_dataset_exists{dataset="tank/services/openproject"} 0' "$nosnap"
assert_line 'zfs_snapshot_dataset_missing{dataset="tank/services/openproject"} 1' "$nosnap"
if grep -Eq '^[0-9]+$' "$nosnap"; then
  fail "bare number line when the pool has no snapshots"
fi

# A failed filesystem or snapshot list must not replace the previous file.
printf 'zfs_sentinel 1\n' >"$metrics"
if ZFS_FAIL_FILESYSTEMS=1 bash "$script" --metrics-file "$metrics" tank/services/plex \
  >"$root/failfs.stdout" 2>"$root/failfs.stderr"; then
  fail "filesystem list failure was published"
fi
assert_line 'zfs_sentinel 1' "$metrics"
grep -F 'zfs list failed' "$root/failfs.stderr" >/dev/null || fail "filesystem list failure was not logged"

if ZFS_FAIL_SNAPSHOTS=1 bash "$script" --metrics-file "$metrics" tank/services/plex \
  >"$root/failsn.stdout" 2>"$root/failsn.stderr"; then
  fail "snapshot list failure was published"
fi
assert_line 'zfs_sentinel 1' "$metrics"
grep -F 'zfs list snapshots failed' "$root/failsn.stderr" >/dev/null || fail "snapshot list failure was not logged"

echo "zfs-snapshot-metrics tests passed"
