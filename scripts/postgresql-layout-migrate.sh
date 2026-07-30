#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <check|migrate> <dataset> <major-version> [data-root]" >&2
  exit 2
}

fail() {
  echo "PostgreSQL layout migration error: $*" >&2
  exit 1
}

[[ $# -ge 3 && $# -le 4 ]] || usage

action="$1"
dataset="$2"
major_version="$3"
data_root="${4:-/var/lib/postgresql}"
pgdata="${data_root}/${major_version}"

[[ "$action" == "check" || "$action" == "migrate" ]] || usage
[[ "$major_version" =~ ^[0-9]+$ ]] || fail "major version must be numeric"
[[ "$data_root" == /* && "$data_root" != "/" ]] || fail "data root must be an absolute path other than /"

for command in zfs findmnt find install mv cp rm rmdir sync systemctl pgrep; do
  command -v "$command" >/dev/null || fail "required command is missing: $command"
done

dataset_mountpoint="$(zfs get -H -o value mountpoint "$dataset")"

if [[ "$dataset_mountpoint" == "$data_root" ]]; then
  [[ -f "$pgdata/PG_VERSION" ]] || fail "dataset is mounted at $data_root but $pgdata is not a valid cluster"
  actual_version="$(cat "$pgdata/PG_VERSION")"
  [[ "$actual_version" == "$major_version" ]] || fail "$pgdata contains PostgreSQL $actual_version"
  [[ ! -f "$data_root/PG_VERSION" ]] || fail "a legacy cluster still exists at $data_root"
  echo "PostgreSQL layout is already migrated: $dataset -> $data_root, PGDATA=$pgdata"
  exit 0
fi

[[ "$dataset_mountpoint" == "$pgdata" ]] ||
  fail "$dataset is mounted at $dataset_mountpoint, expected $pgdata or $data_root"
[[ -f "$pgdata/PG_VERSION" ]] || fail "legacy cluster is missing $pgdata/PG_VERSION"
actual_version="$(cat "$pgdata/PG_VERSION")"
[[ "$actual_version" == "$major_version" ]] || fail "legacy cluster contains PostgreSQL $actual_version"

if [[ "$action" == "check" ]]; then
  echo "PostgreSQL layout migration is required: $dataset -> $data_root, PGDATA=$pgdata"
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || fail "migrate must run as root"
[[ ! -e /run/postgresql-major-upgrade-target ]] || fail "major-upgrade gate is active; disable it before migrating storage layout"
systemctl is-active --quiet postgresql.service && fail "postgresql.service is still active"
pgrep -u postgres -x postgres >/dev/null && fail "a postgres server process is still running"
pgrep -x pgbackrest >/dev/null && fail "a pgBackRest process is still running"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
snapshot="${dataset}@pre-stable-layout-${timestamp}"
state_dir="$(mktemp -d "/run/postgresql-layout-${timestamp}.XXXXXX")"

trap 'rm -rf "$state_dir"' EXIT

shopt -s nullglob
for state_path in \
  "$data_root"/.preseed-* \
  "$data_root"/.postpreseed-* \
  "$data_root"/.major-upgrade-* \
  "$data_root"/provisioning; do
  [[ -e "$state_path" ]] || continue
  [[ "$(basename "$state_path")" == ".preseed-in-progress" ]] && continue
  cp -a -- "$state_path" "$state_dir/"
done

echo "Creating rollback snapshot $snapshot"
zfs snapshot "$snapshot"
zfs unmount "$dataset"

for parent_entry in "$data_root"/* "$data_root"/.[!.]* "$data_root"/..?*; do
  [[ -e "$parent_entry" ]] || continue
  entry_name="$(basename "$parent_entry")"
  case "$entry_name" in
    "$major_version"|.preseed-*|.postpreseed-*|.major-upgrade-*|provisioning) ;;
    *) fail "unexpected entry beneath the old parent mount: $parent_entry" ;;
  esac
done

rm -rf -- "$data_root"/.preseed-* "$data_root"/.postpreseed-* "$data_root"/.major-upgrade-* "$data_root"/provisioning
rmdir "$pgdata" 2>/dev/null || fail "old mount directory is not empty: $pgdata"

zfs set "mountpoint=$data_root" "$dataset"
findmnt -rn -S "$dataset" -T "$data_root" >/dev/null || zfs mount "$dataset"
findmnt -rn -S "$dataset" -T "$data_root" >/dev/null || fail "$dataset did not mount at $data_root"
[[ -f "$data_root/PG_VERSION" ]] || fail "legacy cluster was not found after remounting $dataset"

install -d -m 0700 -o postgres -g postgres "$pgdata"
mapfile -d '' cluster_entries < <(
  find "$data_root" -mindepth 1 -maxdepth 1 \
    ! -name "$major_version" \
    ! -name .zfs \
    -print0
)
[[ ${#cluster_entries[@]} -gt 0 ]] || fail "no cluster entries found to move"
mv -- "${cluster_entries[@]}" "$pgdata/"

for state_path in "$state_dir"/* "$state_dir"/.[!.]* "$state_dir"/..?*; do
  [[ -e "$state_path" ]] || continue
  cp -a -- "$state_path" "$data_root/"
done

chown postgres:postgres "$data_root" "$pgdata"
chmod 0700 "$data_root" "$pgdata"
sync

[[ -f "$pgdata/PG_VERSION" ]] || fail "migration completed without $pgdata/PG_VERSION"
[[ "$(cat "$pgdata/PG_VERSION")" == "$major_version" ]] || fail "migrated cluster has the wrong version"
[[ ! -f "$data_root/PG_VERSION" ]] || fail "legacy PG_VERSION remains at $data_root"

echo "PostgreSQL layout migration completed"
echo "Rollback snapshot: $snapshot"
echo "Dataset mountpoint: $data_root"
echo "PGDATA: $pgdata"
exit 0
