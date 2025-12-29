#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
A CLI dashboard for monitoring the status of various backup systems via Prometheus.

Usage:
    python backup-status.py [--prometheus-url URL] [--api-key KEY]

Environment Variables:
    PROMETHEUS_URL: URL of the Prometheus server (default: http://localhost:9090)
    PROMETHEUS_API_KEY: API key for X-Api-Key header authentication
"""

import argparse
import datetime
import os
import sys
from typing import Dict, List, Tuple

try:
    import requests
except ImportError:
    print(
        "Error: 'requests' library not found. Install it with: pip install requests rich",
        file=sys.stderr,
    )
    sys.exit(1)

try:
    from rich.console import Console
    from rich.table import Table
except ImportError:
    print(
        "Error: 'rich' library not found. Install it with: pip install requests rich",
        file=sys.stderr,
    )
    sys.exit(1)

# --- Configuration ---
DEFAULT_PROMETHEUS_URL = "http://forge.holthome.net:9090"
STALE_THRESHOLD_HOURS = 26  # Consider backups stale after 26 hours

# --- PromQL Queries ---
# These match the actual metrics exported by your NixOS configuration
QUERIES = {
    # pgBackRest - last successful backup completion time by repo and type
    "pgbackrest_age": "time() - pgbackrest_backup_last_good_completion_seconds",
    "pgbackrest_repo_errors": "pgbackrest_repo_status != 0",
    "pgbackrest_stanza_status": "pgbackrest_stanza_status",
    "pgbackrest_repo_info": "pgbackrest_repo_info",
    # Syncoid - ZFS replication status
    "syncoid_age": "time() - syncoid_replication_last_success_timestamp",
    "syncoid_status": "syncoid_replication_status",
    # Restic - backup status
    "restic_age": "time() - restic_backup_last_success_timestamp",
    "restic_status": "restic_backup_status",
}


def query_prometheus(
    base_url: str, query: str, headers: Dict[str, str] = None
) -> List[Dict]:
    """Sends a query to the Prometheus API and returns the result vector."""
    api_url = f"{base_url}/api/v1/query"
    try:
        response = requests.get(
            api_url, params={"query": query}, headers=headers, timeout=10
        )
        response.raise_for_status()
        data = response.json()
        if data["status"] == "success" and data["data"]["resultType"] == "vector":
            return data["data"]["result"]
        return []
    except requests.exceptions.RequestException as e:
        print(f"Error querying Prometheus at {base_url}: {e}", file=sys.stderr)
        return []


def seconds_to_human_readable(seconds: float) -> str:
    """Converts seconds into a human-readable string like '1d 2h 3m'."""
    if seconds < 0:
        return "in the future"

    delta = datetime.timedelta(seconds=seconds)
    days = delta.days
    hours, rem = divmod(delta.seconds, 3600)
    minutes, _ = divmod(rem, 60)

    parts = []
    if days > 0:
        parts.append(f"{days}d")
    if hours > 0:
        parts.append(f"{hours}h")
    if minutes > 0 or not parts:
        parts.append(f"{minutes}m")

    return " ".join(parts) + " ago"


def get_status_for_age(age_seconds: float, system: str = "backup") -> Tuple[str, str]:
    """Determines the status and color based on age."""
    if age_seconds > STALE_THRESHOLD_HOURS * 3600:
        return (
            "[bold yellow]STALE[/bold yellow]",
            f"Last success > {STALE_THRESHOLD_HOURS}h ago",
        )
    return "[bold green]OK[/bold green]", "Healthy"


def get_syncoid_status(status_value: float) -> Tuple[str, str]:
    """Interprets syncoid status value (0=fail, 1=success, 2=in-progress)."""
    if status_value == 0:
        return "[bold red]FAILED[/bold red]", "Last run failed"
    elif status_value == 2:
        return "[bold cyan]RUNNING[/bold cyan]", "In progress"
    else:  # 1 = success
        return "[bold green]OK[/bold green]", "Success"


def get_restic_status(status_value: float) -> Tuple[str, str]:
    """Interprets restic status value (1=success, 0=failure)."""
    if status_value == 0:
        return "[bold red]FAILED[/bold red]", "Last run failed"
    else:
        return "[bold green]OK[/bold green]", "Success"


def main():
    """Main function to query data and render the dashboard."""
    parser = argparse.ArgumentParser(description="Backup Status Dashboard")
    parser.add_argument(
        "--prometheus-url",
        default=os.getenv("PROMETHEUS_URL", DEFAULT_PROMETHEUS_URL),
        help=f"Prometheus server URL (default: {DEFAULT_PROMETHEUS_URL})",
    )
    parser.add_argument(
        "--api-key",
        default=os.getenv("PROMETHEUS_API_KEY"),
        help="API key for X-Api-Key header authentication (or set PROMETHEUS_API_KEY)",
    )
    args = parser.parse_args()

    console = Console()

    # Setup authentication headers if API key provided
    headers = None
    if args.api_key:
        headers = {"X-Api-Key": args.api_key}

    # Fetch all data from Prometheus
    results = {
        name: query_prometheus(args.prometheus_url, query, headers)
        for name, query in QUERIES.items()
    }

    table = Table(
        title="Backup Status Dashboard", show_header=True, header_style="bold magenta"
    )
    table.add_column("System", style="cyan", no_wrap=True)
    table.add_column("Target/Repo", style="dim")
    table.add_column("Type", style="dim")
    table.add_column("Status", justify="center")
    table.add_column("Last Success", justify="right")
    table.add_column("Details", style="dim")

    # --- pgBackRest ---
    pgbackrest_rows = []

    # Build repo info map from Prometheus
    repo_info = {}
    for res in results.get("pgbackrest_repo_info", []):
        repo_key = res["metric"].get("repo_key", "unknown")
        repo_name = res["metric"].get("repo_name", "unknown")
        repo_location = res["metric"].get("repo_location", "")
        if repo_location:
            repo_info[repo_key] = f"{repo_name} ({repo_location})"
        else:
            repo_info[repo_key] = repo_name

    for res in results.get("pgbackrest_age", []):
        repo = res["metric"].get("repo_key", "unknown")
        repo_display = repo_info.get(repo, f"repo{repo}")
        backup_type = res["metric"].get("type", "unknown")
        age_sec = float(res["value"][1])

        # Check for repo errors
        has_error = False
        for err_res in results.get("pgbackrest_repo_errors", []):
            if err_res["metric"].get("repo_key") == repo:
                has_error = True
                break

        if has_error:
            status = "[bold red]ERROR[/bold red]"
            details = "Repository error"
        else:
            status, details = get_status_for_age(age_sec)

        pgbackrest_rows.append(
            (repo, repo_display, backup_type, age_sec, status, details)
        )

    # Sort by repo, then type
    pgbackrest_rows.sort(key=lambda x: (x[0], x[2]))
    for _, repo_display, backup_type, age_sec, status, details in pgbackrest_rows:
        table.add_row(
            "pgBackRest",
            repo_display,
            backup_type,
            status,
            seconds_to_human_readable(age_sec),
            details,
        )

    # --- Syncoid ---
    syncoid_rows = []
    for res in results.get("syncoid_age", []):
        dataset = res["metric"].get("dataset", "unknown")
        target_name = res["metric"].get("target_name", "unknown")
        target_location = res["metric"].get("target_location", "")
        # Build display name similar to pgBackRest: "NFS (nas-1)"
        if target_location:
            target_display = f"{target_name} ({target_location})"
        else:
            target_display = target_name
        age_sec = float(res["value"][1])

        # Get current status
        current_status = None
        for status_res in results.get("syncoid_status", []):
            if status_res["metric"].get("dataset") == dataset:
                current_status = float(status_res["value"][1])
                break

        if current_status is not None:
            status, details = get_syncoid_status(current_status)
            # If status is success (1), check for staleness
            if current_status == 1:
                age_status, age_details = get_status_for_age(age_sec)
                if "STALE" in age_status:
                    status, details = age_status, age_details
        else:
            # If no status metric, rely on age alone
            status, details = get_status_for_age(age_sec)

        syncoid_rows.append((dataset, target_display, age_sec, status, details))

    # Sort by dataset
    syncoid_rows.sort(key=lambda x: x[0])
    for dataset, target_display, age_sec, status, details in syncoid_rows:
        # Shorten dataset name for display
        dataset_short = dataset.split("/")[-1] if "/" in dataset else dataset
        table.add_row(
            "Syncoid",
            target_display,
            dataset_short,
            status,
            seconds_to_human_readable(age_sec),
            details,
        )

    # --- Restic ---
    restic_rows = []
    for res in results.get("restic_age", []):
        job = res["metric"].get("backup_job", "unknown")
        repo = res["metric"].get("repository", "unknown")
        repo_name = res["metric"].get("repository_name", "")
        repo_location = res["metric"].get("repository_location", "")
        age_sec = float(res["value"][1])

        # Build target display matching pgBackRest/Syncoid pattern
        target_display = (
            f"{repo_name} ({repo_location})" if repo_name and repo_location else repo
        )

        # Get current status
        current_status = None
        for status_res in results.get("restic_status", []):
            if status_res["metric"].get("backup_job") == job:
                current_status = float(status_res["value"][1])
                break

        if current_status is not None:
            status, details = get_restic_status(current_status)
            # If status is success (1), check for staleness
            if current_status == 1:
                age_status, age_details = get_status_for_age(age_sec)
                if "STALE" in age_status:
                    status, details = age_status, age_details
        else:
            # If no status metric, rely on age alone
            status, details = get_status_for_age(age_sec)

        restic_rows.append((job, target_display, age_sec, status, details))

    # Sort by job name
    restic_rows.sort(key=lambda x: x[0])
    for job, target_display, age_sec, status, details in restic_rows:
        table.add_row(
            "Restic",
            target_display,
            job,
            status,
            seconds_to_human_readable(age_sec),
            details,
        )

    if not table.rows:
        console.print(
            "[yellow]No backup metrics found. Check your Prometheus queries and exporters.[/yellow]"
        )
        console.print(f"\n[dim]Querying: {args.prometheus_url}[/dim]")
        return 1

    console.print(table)
    console.print(f"\n[dim]Data source: {args.prometheus_url}[/dim]")
    console.print(f"[dim]Stale threshold: {STALE_THRESHOLD_HOURS} hours[/dim]")

    return 0


if __name__ == "__main__":
    sys.exit(main())
