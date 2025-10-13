{ pkgs, ... }:

pkgs.stdenv.mkDerivation {
  pname = "pg-backup-scripts";
  version = "1.0.0";

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/bin

    # Pre-snapshot script: pg_backup_start
    cat > $out/bin/pg-backup-start <<'EOF'
    #!/usr/bin/env bash
    set -euo pipefail

    # Put PostgreSQL into backup mode before ZFS snapshot
    # This creates a backup_label file that makes the snapshot a proper base backup

    if [[ "$(id -u)" -ne 0 ]]; then
       echo "ERROR: This script must be run as root" >&2
       exit 1
    fi

    echo "[$(date -Iseconds)] Starting PostgreSQL backup mode for Sanoid snapshot..."

    # Use pg_backup_start (PostgreSQL 15+) with:
    # - Label: 'sanoid snapshot'
    # - Fast checkpoint: true (don't wait for checkpoint to complete slowly)
    if ! sudo -u postgres psql -d postgres -c "SELECT pg_backup_start('sanoid snapshot', true);" >/dev/null 2>&1; then
        echo "ERROR: Failed to start PostgreSQL backup mode" >&2
        exit 1
    fi

    # Brief sleep to ensure backup_label file is written to disk
    sleep 1

    echo "[$(date -Iseconds)] PostgreSQL is in backup mode. Proceeding with snapshot."
    exit 0
    EOF

    # Post-snapshot script: pg_backup_stop
    cat > $out/bin/pg-backup-stop <<'EOF'
    #!/usr/bin/env bash
    set -euo pipefail

    # Take PostgreSQL out of backup mode after ZFS snapshot
    # This removes the backup_label file from the live system

    if [[ "$(id -u)" -ne 0 ]]; then
       echo "ERROR: This script must be run as root" >&2
       exit 1
    fi

    echo "[$(date -Iseconds)] Ending PostgreSQL backup mode..."

    # Use pg_backup_stop (PostgreSQL 15+)
    # The wait_for_archive parameter defaults to false, which is what we want
    # WALs will be archived by the normal archive_command process
    if ! sudo -u postgres psql -d postgres -c "SELECT * FROM pg_backup_stop();" >/dev/null 2>&1; then
        echo "ERROR: Failed to stop PostgreSQL backup mode" >&2
        exit 1
    fi

    echo "[$(date -Iseconds)] PostgreSQL backup mode finished."
    exit 0
    EOF

    chmod +x $out/bin/pg-backup-start
    chmod +x $out/bin/pg-backup-stop
  '';

  meta = with pkgs.lib; {
    description = "PostgreSQL backup coordination scripts for ZFS snapshots";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
