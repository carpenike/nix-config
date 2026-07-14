#!/usr/bin/env bash

set -euo pipefail

service="restic-backup-service-plex.service"
container="plex"
tag="plex"
plex_sqlite="/usr/lib/plexmediaserver/Plex SQLite"
base="/var/lib/backup-snapshots/service-plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
active="$base/com.plexapp.plugins.library.db"
wal="$active-wal"
shm="$active-shm"

if (( EUID != 0 )); then
  echo "This restore test must run as root" >&2
  exit 2
fi

if ! systemctl is-active --quiet podman-plex.service; then
  echo "Plex must be running so its bundled SQLite engine is available" >&2
  exit 1
fi

if ! podman exec "$container" test -x "$plex_sqlite"; then
  echo "Plex SQLite is unavailable at $plex_sqlite" >&2
  exit 1
fi

if ! systemctl cat "$service" >/dev/null 2>&1; then
  echo "Unknown Plex Restic service: $service" >&2
  exit 2
fi

service_script=$(systemctl cat "$service" --no-pager | sed -n 's/^ExecStart=//p' | awk '{print $1}' | head -1)
restic=$(grep -o '/nix/store/[^" ]*-restic-[^" ]*/bin/restic' "$service_script" | head -1)
environment=$(systemctl show "$service" -p Environment --value)

for assignment in $environment; do
  case $assignment in
    RESTIC_REPOSITORY=*) export RESTIC_REPOSITORY=${assignment#RESTIC_REPOSITORY=} ;;
    RESTIC_PASSWORD_FILE=*) export RESTIC_PASSWORD_FILE=${assignment#RESTIC_PASSWORD_FILE=} ;;
    SSL_CERT_FILE=*) export SSL_CERT_FILE=${assignment#SSL_CERT_FILE=} ;;
  esac
done

if [[ -z ${RESTIC_REPOSITORY:-} || -z ${RESTIC_PASSWORD_FILE:-} ]]; then
  echo "Unable to discover Plex Restic repository credentials" >&2
  exit 2
fi

available=$(df --output=avail -B1 /transcode | tail -1 | tr -d ' ')
if [[ ! $available =~ ^[0-9]+$ ]] || (( available < 3221225472 )); then
  echo "Plex restore validation requires at least 3 GiB free in /transcode" >&2
  exit 1
fi

work="/transcode/plex-restore-validation-$$"
restore_root="$work/restore"
nodes="$work/nodes.jsonl"

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM
mkdir -p "$restore_root"

snapshots=$($restic snapshots --host "$(hostname)" --tag "$tag" --latest 1 --json --no-cache)
snapshot=$(jq -r 'if length == 0 then "" else max_by(.time).id end' <<<"$snapshots")
snapshot_time=$(jq -r 'if length == 0 then "" else max_by(.time).time end' <<<"$snapshots")

if [[ -z $snapshot ]]; then
  echo "No Plex snapshots found" >&2
  exit 1
fi

$restic ls --json "$snapshot" --no-cache > "$nodes"

has_path() {
  local path=$1
  jq -e --arg path "$path" 'select(.struct_type == "node" and .type == "file" and .path == $path)' "$nodes" >/dev/null
}

for required in "$active" "$wal"; do
  if ! has_path "$required"; then
    echo "Required Plex database artifact missing from snapshot: $required" >&2
    exit 1
  fi
done

scheduled_prefix="$base/com.plexapp.plugins.library.db-"
scheduled=$(
  jq -r --arg prefix "$scheduled_prefix" '
    select(
      .struct_type == "node"
      and .type == "file"
      and (.path | startswith($prefix))
      and (.path | test("[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    )
    | .path
  ' "$nodes" | sort | tail -1
)

if [[ -z $scheduled ]]; then
  echo "No dated Plex library database copy found in snapshot $snapshot" >&2
  exit 1
fi

restore_args=(
  "$restic" restore "$snapshot"
  --target "$restore_root"
  --no-cache
  --include "$active"
  --include "$wal"
  --include "$scheduled"
)
if has_path "$shm"; then
  restore_args+=(--include "$shm")
fi
"${restore_args[@]}"

validate_database() {
  local source=$1
  local database="$restore_root$source"
  local integrity tables metadata

  if [[ ! -s $database ]]; then
    echo "Restored Plex database is missing or empty: $database" >&2
    return 1
  fi

  integrity=$(podman exec --user 0 "$container" "$plex_sqlite" -batch "$database" 'PRAGMA integrity_check;')
  tables=$(podman exec --user 0 "$container" "$plex_sqlite" -batch "$database" "SELECT count(*) FROM sqlite_master WHERE type='table';")
  metadata=$(podman exec --user 0 "$container" "$plex_sqlite" -batch "$database" 'SELECT count(*) FROM metadata_items;')

  if [[ $integrity != ok || ! $tables =~ ^[0-9]+$ || ! $metadata =~ ^[0-9]+$ || $tables -eq 0 || $metadata -eq 0 ]]; then
    echo "Plex database validation failed: $database integrity=$integrity tables=$tables metadata_items=$metadata" >&2
    return 1
  fi

  printf 'PASS %s size=%s integrity=%s tables=%s metadata_items=%s\n' \
    "$(basename "$database")" "$(stat -c %s "$database")" "$integrity" "$tables" "$metadata"
}

validate_database "$scheduled"
validate_database "$active"

if ! systemctl is-active --quiet podman-plex.service; then
  echo "Plex stopped during restore validation" >&2
  exit 1
fi

printf 'snapshot=%s time=%s restored_bytes=%s\n' \
  "$snapshot" "$snapshot_time" "$(du -sb "$restore_root" | cut -f1)"
