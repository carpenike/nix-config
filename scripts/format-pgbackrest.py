#!/usr/bin/env python3
"""
Format pgBackRest JSON output into a clean summary table.
Usage: pgbackrest --stanza=main info --output=json | python3 format-pgbackrest.py
"""

import json
import sys
from datetime import datetime
from collections import defaultdict


def format_size(size_bytes):
    """Convert bytes to human-readable format."""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if abs(size_bytes) < 1024:
            return f"{size_bytes:.1f}{unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f}PB"


def format_duration(seconds):
    """Format duration in human-readable format."""
    if seconds < 60:
        return f"{seconds}s"
    elif seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    else:
        hours = seconds // 3600
        minutes = (seconds % 3600) // 60
        return f"{hours}h {minutes}m"


def format_timestamp(ts):
    """Format unix timestamp to readable date."""
    return datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M')


def time_ago(ts):
    """Calculate time ago from timestamp."""
    now = datetime.now()
    then = datetime.fromtimestamp(ts)
    delta = now - then

    if delta.days > 0:
        return f"{delta.days}d ago"
    elif delta.seconds >= 3600:
        return f"{delta.seconds // 3600}h ago"
    elif delta.seconds >= 60:
        return f"{delta.seconds // 60}m ago"
    else:
        return f"{delta.seconds}s ago"


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON: {e}", file=sys.stderr)
        sys.exit(1)

    if not data:
        print("No data received")
        sys.exit(1)

    # Handle array format (pgbackrest returns array)
    if isinstance(data, list):
        data = data[0] if data else {}

    stanza = data.get('name', 'unknown')
    status = data.get('status', {})
    repos = data.get('repo', [])
    backups = data.get('backup', [])

    # Header
    print()
    print("╔══════════════════════════════════════════════════════════════════════════════╗")
    print(f"║  📦 pgBackRest Backup Summary - Stanza: {stanza:<37} ║")
    print("╚══════════════════════════════════════════════════════════════════════════════╝")
    print()

    # Repository Status
    print("📁 Repository Status")
    print("─" * 60)
    for repo in repos:
        key = repo.get('key', '?')
        repo_status = repo.get('status', {})
        status_msg = repo_status.get('message', 'unknown')
        status_icon = "✅" if status_msg == "ok" else "❌"
        print(f"  Repo {key}: {status_icon} {status_msg}")
    print()

    if not backups:
        print("  No backups found")
        return

    # Group backups by repository and type
    repo_stats = defaultdict(lambda: {'full': [], 'incr': [], 'diff': []})

    for backup in backups:
        repo_key = backup.get('database', {}).get('repo-key', 1)
        backup_type = backup.get('type', 'unknown')
        repo_stats[repo_key][backup_type].append(backup)

    # Summary per repository
    print("📊 Backup Summary by Repository")
    print("─" * 60)

    for repo_key in sorted(repo_stats.keys()):
        stats = repo_stats[repo_key]
        full_count = len(stats['full'])
        incr_count = len(stats['incr'])
        diff_count = len(stats['diff'])
        total = full_count + incr_count + diff_count

        print(f"  Repo {repo_key}: {total} backups ({full_count} full, {incr_count} incr, {diff_count} diff)")
    print()

    # Latest backup per repo
    print("🕐 Latest Backups")
    print("─" * 60)
    print(f"  {'Repo':<6} {'Type':<6} {'Timestamp':<18} {'Age':<10} {'DB Size':<10} {'Backup Δ':<10}")
    print(f"  {'─'*6} {'─'*6} {'─'*18} {'─'*10} {'─'*10} {'─'*10}")

    for repo_key in sorted(repo_stats.keys()):
        # Get most recent backup for this repo
        all_backups = []
        for backup_type in ['full', 'incr', 'diff']:
            all_backups.extend(repo_stats[repo_key][backup_type])

        if not all_backups:
            continue

        # Sort by timestamp
        latest = max(all_backups, key=lambda x: x.get('timestamp', {}).get('stop', 0))

        ts = latest.get('timestamp', {}).get('stop', 0)
        backup_type = latest.get('type', '?')
        info = latest.get('info', {})
        db_size = info.get('size', 0)
        delta_size = info.get('delta', 0)

        print(f"  {repo_key:<6} {backup_type:<6} {format_timestamp(ts):<18} {time_ago(ts):<10} {format_size(db_size):<10} {format_size(delta_size):<10}")
    print()

    # Full backups (most recent per repo)
    print("💾 Full Backups (Base Snapshots)")
    print("─" * 60)
    print(f"  {'Repo':<6} {'Label':<26} {'Timestamp':<18} {'Size':<12}")
    print(f"  {'─'*6} {'─'*26} {'─'*18} {'─'*12}")

    for repo_key in sorted(repo_stats.keys()):
        full_backups = repo_stats[repo_key]['full']
        if not full_backups:
            continue

        # Show most recent full backup
        latest_full = max(full_backups, key=lambda x: x.get('timestamp', {}).get('stop', 0))
        label = latest_full.get('label', 'unknown')
        ts = latest_full.get('timestamp', {}).get('stop', 0)
        repo_info = latest_full.get('info', {}).get('repository', {})
        size = repo_info.get('size', 0)

        print(f"  {repo_key:<6} {label:<26} {format_timestamp(ts):<18} {format_size(size):<12}")
    print()

    # Recent incremental backups (last 5 per repo)
    print("📈 Recent Incremental Backups (Last 5 per Repo)")
    print("─" * 60)

    for repo_key in sorted(repo_stats.keys()):
        incr_backups = repo_stats[repo_key]['incr']
        if not incr_backups:
            continue

        # Sort by timestamp and get last 5
        sorted_incr = sorted(incr_backups, key=lambda x: x.get('timestamp', {}).get('stop', 0), reverse=True)[:5]

        print(f"  Repo {repo_key}:")
        for backup in sorted_incr:
            ts = backup.get('timestamp', {}).get('stop', 0)
            info = backup.get('info', {})
            delta = info.get('delta', 0)
            repo_delta = info.get('repository', {}).get('delta', 0)
            duration = backup.get('timestamp', {}).get('stop', 0) - backup.get('timestamp', {}).get('start', 0)

            print(f"    {format_timestamp(ts)} | Δ {format_size(delta):>8} → {format_size(repo_delta):>8} (compressed) | {format_duration(duration):>6}")
        print()

    # WAL archive status
    print("📜 WAL Archive Range")
    print("─" * 60)

    # Get first and last WAL from backups
    all_backups_sorted = sorted(backups, key=lambda x: x.get('timestamp', {}).get('stop', 0))
    if all_backups_sorted:
        first_backup = all_backups_sorted[0]
        last_backup = all_backups_sorted[-1]

        first_wal = first_backup.get('archive', {}).get('start', 'N/A')
        last_wal = last_backup.get('archive', {}).get('stop', 'N/A')

        print(f"  First WAL: {first_wal}")
        print(f"  Last WAL:  {last_wal}")
    print()

    # Storage summary
    print("💿 Storage Summary")
    print("─" * 60)

    total_repo_size = defaultdict(int)
    for backup in backups:
        repo_key = backup.get('database', {}).get('repo-key', 1)
        repo_info = backup.get('info', {}).get('repository', {})
        # Only count size from full backups (incrementals reference fulls)
        if backup.get('type') == 'full':
            total_repo_size[repo_key] = max(total_repo_size[repo_key], repo_info.get('size', 0))

    for repo_key in sorted(total_repo_size.keys()):
        print(f"  Repo {repo_key}: ~{format_size(total_repo_size[repo_key])} (full backup size)")

    print()
    print("─" * 60)
    print(f"  Total backups: {len(backups)} | Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print()


if __name__ == '__main__':
    main()
