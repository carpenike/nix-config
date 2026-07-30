#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: postgresql-major-upgrade <gate-enable|gate-disable|gate-status|prepare|reset|check|upgrade>" >&2
  exit 2
}

fail() {
  echo "PostgreSQL major upgrade error: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
action="$1"
case "$action" in
  gate-enable|gate-disable|gate-status|prepare|reset|check|upgrade) ;;
  *) usage ;;
esac

required_variables=(
  PG_OLD_BIN
  PG_NEW_BIN
  PG_OLD_DATA
  PG_NEW_DATA
  PG_WORK_DIR
  PG_OLD_VERSION
  PG_NEW_VERSION
  PG_INITDB_LOCALE
  PG_MAINTENANCE_MARKER
)

for variable_name in "${required_variables[@]}"; do
  [[ -n "${!variable_name:-}" ]] || fail "required environment variable is missing: $variable_name"
done

case "$action" in
  gate-enable)
    [[ "$(id -u)" -eq 0 ]] || fail "gate-enable must run as root"
    printf '%s\n' "$PG_NEW_DATA" > "$PG_MAINTENANCE_MARKER"
    chmod 0644 "$PG_MAINTENANCE_MARKER"
    echo "PostgreSQL major-upgrade gate enabled for $PG_NEW_DATA"
    exit 0
    ;;
  gate-disable)
    [[ "$(id -u)" -eq 0 ]] || fail "gate-disable must run as root"
    rm -f "$PG_MAINTENANCE_MARKER"
    echo "PostgreSQL major-upgrade gate disabled"
    exit 0
    ;;
  gate-status)
    if [[ -e "$PG_MAINTENANCE_MARKER" ]]; then
      echo "PostgreSQL major-upgrade target: $(cat "$PG_MAINTENANCE_MARKER")"
    else
      echo "PostgreSQL major-upgrade gate is disabled"
    fi
    exit 0
    ;;
esac

[[ "$(id -un)" == "postgres" ]] || fail "run this command as the postgres user"
[[ -x "$PG_OLD_BIN/postgres" ]] || fail "old postgres binary is missing"
[[ -x "$PG_NEW_BIN/postgres" ]] || fail "new postgres binary is missing"
[[ -x "$PG_NEW_BIN/pg_upgrade" ]] || fail "new pg_upgrade binary is missing"
[[ -f "$PG_OLD_DATA/PG_VERSION" ]] || fail "old cluster is missing PG_VERSION"
[[ "$(cat "$PG_OLD_DATA/PG_VERSION")" == "$PG_OLD_VERSION" ]] || fail "old cluster version does not match"
data_root="$(dirname "$PG_NEW_DATA")"
[[ "$(dirname "$PG_OLD_DATA")" == "$data_root" ]] || fail "old and new clusters must share a data root"
completion_marker="$data_root/.major-upgrade-to-$PG_NEW_VERSION-completed"

prepare_target() {
  if [[ -f "$PG_NEW_DATA/PG_VERSION" ]]; then
    [[ "$(cat "$PG_NEW_DATA/PG_VERSION")" == "$PG_NEW_VERSION" ]] || fail "target cluster version does not match"
    echo "PostgreSQL $PG_NEW_VERSION target cluster is already initialized"
    return
  fi

  if [[ -d "$PG_NEW_DATA" && -n "$(ls -A "$PG_NEW_DATA")" ]]; then
    fail "target data directory is non-empty: $PG_NEW_DATA"
  fi

  install -d -m 0700 "$PG_NEW_DATA" "$PG_WORK_DIR"
  "$PG_NEW_BIN/initdb" \
    --pgdata="$PG_NEW_DATA" \
    --username=postgres \
    --encoding=UTF8 \
    --locale-provider=libc \
    --locale="$PG_INITDB_LOCALE" \
    --auth-local=peer \
    --auth-host=scram-sha-256

  [[ "$(cat "$PG_NEW_DATA/PG_VERSION")" == "$PG_NEW_VERSION" ]] || fail "initdb created an unexpected target version"
}

require_offline_clusters() {
  [[ -e "$PG_MAINTENANCE_MARKER" ]] || fail "maintenance gate is missing: $PG_MAINTENANCE_MARKER"
  [[ "$(cat "$PG_MAINTENANCE_MARKER")" == "$PG_NEW_DATA" ]] || fail "maintenance gate targets the wrong data directory"
  systemctl is-active --quiet postgresql.service && fail "postgresql.service is still active"
  pgrep -u postgres -x postgres >/dev/null && fail "a postgres server process is still running"
  pgrep -x pgbackrest >/dev/null && fail "a pgBackRest process is still running"

  old_state="$("$PG_OLD_BIN/pg_controldata" "$PG_OLD_DATA" | awk -F: '/Database cluster state/ {sub(/^[[:space:]]+/, "", $2); print $2}')"
  [[ "$old_state" == "shut down" ]] || fail "old cluster state is '$old_state', expected 'shut down'"
}

pg_upgrade_args=(
  "--old-bindir=$PG_OLD_BIN"
  "--new-bindir=$PG_NEW_BIN"
  "--old-datadir=$PG_OLD_DATA"
  "--new-datadir=$PG_NEW_DATA"
  "--old-options=-c archive_mode=off -c shared_preload_libraries=timescaledb,pg_stat_statements"
  "--new-options=-c archive_mode=off -c shared_preload_libraries=timescaledb,pg_stat_statements"
  "--jobs=4"
)

run_check() {
  prepare_target
  require_offline_clusters
  install -d -m 0700 "$PG_WORK_DIR"
  cd "$PG_WORK_DIR"
  "$PG_NEW_BIN/pg_upgrade" "${pg_upgrade_args[@]}" --check
}

case "$action" in
  prepare)
    prepare_target
    ;;
  reset)
    require_offline_clusters
    [[ "$PG_NEW_DATA" == "$data_root/$PG_NEW_VERSION" ]] || fail "refusing to reset unexpected target path"
    [[ "$PG_WORK_DIR" == "$data_root"/* ]] || fail "refusing to reset unexpected work path"
    if [[ -e "$PG_NEW_DATA" ]]; then
      [[ -f "$PG_NEW_DATA/PG_VERSION" ]] || fail "target exists without PG_VERSION"
      [[ "$(cat "$PG_NEW_DATA/PG_VERSION")" == "$PG_NEW_VERSION" ]] || fail "target contains an unexpected version"
    fi
    rm -rf -- "$PG_NEW_DATA" "$PG_WORK_DIR"
    rm -f -- "$completion_marker"
    prepare_target
    ;;
  check)
    run_check
    ;;
  upgrade)
    run_check
    cd "$PG_WORK_DIR"
    "$PG_NEW_BIN/pg_upgrade" "${pg_upgrade_args[@]}"
    [[ "$(cat "$PG_NEW_DATA/PG_VERSION")" == "$PG_NEW_VERSION" ]] || fail "upgraded target has the wrong version"
    temp_marker="$(mktemp "$data_root/.major-upgrade-to-$PG_NEW_VERSION-completed.XXXXXX")"
    printf 'source_version=%s\ntarget_version=%s\ncompleted_at=%s\n' \
      "$PG_OLD_VERSION" \
      "$PG_NEW_VERSION" \
      "$(date -u --iso-8601=seconds)" \
      > "$temp_marker"
    chmod 0600 "$temp_marker"
    mv -f "$temp_marker" "$completion_marker"
    echo "PostgreSQL $PG_OLD_VERSION to $PG_NEW_VERSION upgrade completed in copy mode"
    echo "The source cluster remains at $PG_OLD_DATA for rollback"
    ;;
esac
exit 0
