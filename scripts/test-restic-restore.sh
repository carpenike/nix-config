#!/usr/bin/env bash

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: test-restic-restore.sh <job-name> [--tag TAG] [--max-size BYTES]

Restores one non-empty regular file from the newest matching snapshot into an
isolated temporary directory. Verifies size, mode, UID, and GID metadata.
EOF
}

case ${1:-} in
  --help|-h)
    usage
    exit 0
    ;;
esac

if (( $# < 1 )); then
  usage >&2
  exit 2
fi

job=$1
shift
tag=${job#service-}
max_size=10485760

while (( $# > 0 )); do
  case $1 in
    --tag)
      shift
      if (( $# == 0 )); then
        echo "--tag requires a value" >&2
        exit 2
      fi
      tag=$1
      ;;
    --max-size)
      shift
      if (( $# == 0 )); then
        echo "--max-size requires a value" >&2
        exit 2
      fi
      max_size=$1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if (( EUID != 0 )); then
  echo "This restore test must run as root" >&2
  exit 2
fi

if [[ ! $max_size =~ ^[0-9]+$ ]] || (( max_size < 1 )); then
  echo "Invalid --max-size value: $max_size" >&2
  exit 2
fi

service="restic-backup-${job}.service"
if ! systemctl cat "$service" >/dev/null 2>&1; then
  echo "Unknown Restic backup service: $service" >&2
  exit 2
fi

service_script=$(systemctl cat "$service" --no-pager | sed -n 's/^ExecStart=//p' | awk '{print $1}' | head -1)
restic=$(grep -o '/nix/store/[^" ]*-restic-[^" ]*/bin/restic' "$service_script" | head -1)
environment=$(systemctl show "$service" -p Environment --value)
repository=""
password_file=""
ssl_cert_file=""

for assignment in $environment; do
  case $assignment in
    RESTIC_REPOSITORY=*) repository=${assignment#RESTIC_REPOSITORY=} ;;
    RESTIC_PASSWORD_FILE=*) password_file=${assignment#RESTIC_PASSWORD_FILE=} ;;
    SSL_CERT_FILE=*) ssl_cert_file=${assignment#SSL_CERT_FILE=} ;;
  esac
done

if [[ -z $repository || -z $password_file ]]; then
  echo "Unable to discover Restic repository environment from $service" >&2
  exit 2
fi

export RESTIC_REPOSITORY=$repository
export RESTIC_PASSWORD_FILE=$password_file
if [[ -n $ssl_cert_file ]]; then
  export SSL_CERT_FILE=$ssl_cert_file
fi

work=$(mktemp -d)
# Invoked through EXIT and signal traps.
# shellcheck disable=SC2329
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

snapshots=$($restic snapshots --host "$(hostname)" --tag "$tag" --json --no-cache)
snapshot=$(jq -r 'if length == 0 then "" else max_by(.time).id end' <<<"$snapshots")
snapshot_time=$(jq -r 'if length == 0 then "" else max_by(.time).time end' <<<"$snapshots")

if [[ -z $snapshot ]]; then
  echo "No snapshots found for job=$job tag=$tag" >&2
  exit 1
fi

node=$(
  $restic ls --json "$snapshot" --no-cache \
    | jq -sc --argjson max "$max_size" '
        map(select(
          .struct_type == "node"
          and .type == "file"
          and .size > 0
          and .size <= $max
        ))
        | if length == 0 then null else min_by(.size) end
      '
)

if [[ $node == null ]]; then
  echo "No non-empty regular file <= $max_size bytes in snapshot $snapshot" >&2
  exit 1
fi

path=$(jq -r '.path' <<<"$node")
expected_size=$(jq -r '.size' <<<"$node")
expected_mode=$(jq -r '.mode' <<<"$node")
expected_uid=$(jq -r '.uid' <<<"$node")
expected_gid=$(jq -r '.gid' <<<"$node")

if [[ $path != /* || $path == *".."* ]]; then
  echo "Refusing unsafe restore path: $path" >&2
  exit 1
fi

restore_root="$work/restore"
mkdir -p "$restore_root"
$restic restore "$snapshot" --target "$restore_root" --include "$path" --no-cache
restored="$restore_root$path"

if [[ ! -f $restored ]]; then
  echo "Restored file missing: $restored" >&2
  exit 1
fi

actual_size=$(stat -c '%s' "$restored")
actual_mode_octal=$(stat -c '%a' "$restored")
actual_mode=$((8#$actual_mode_octal))
actual_uid=$(stat -c '%u' "$restored")
actual_gid=$(stat -c '%g' "$restored")
failures=0

check_equal() {
  local label=$1
  local actual=$2
  local expected=$3
  if [[ $actual == "$expected" ]]; then
    printf 'PASS %s=%s\n' "$label" "$actual"
  else
    printf 'FAIL %s expected=%s actual=%s\n' "$label" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}

printf 'snapshot=%s time=%s path=%s\n' "$snapshot" "$snapshot_time" "$path"
check_equal size "$actual_size" "$expected_size"
check_equal mode "$actual_mode" "$expected_mode"
check_equal uid "$actual_uid" "$expected_uid"
check_equal gid "$actual_gid" "$expected_gid"

exit "$failures"
