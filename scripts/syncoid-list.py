#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
A CLI tool for listing Syncoid ZFS replication status across all configured datasets.

Default mode: Query Prometheus for replication metrics (fast, single HTTP call)
Verify mode: Query each syncoid unit directly via SSH (slower, validates actual state)

Usage:
    syncoid-list [--host HOST] [--dataset NAME] [--target NAME] [--verify] [--json]

Environment Variables:
    NIXOS_DOMAIN: Domain suffix (default: holthome.net)
    PROMETHEUS_API_KEY: API key for Prometheus authentication (for Prometheus mode)
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from typing import Dict, List, Optional, Any

try:
    import requests
except ImportError:
    print("Error: 'requests' library not found. Install it with: pip install requests", file=sys.stderr)
    sys.exit(1)

try:
    from rich.console import Console
    from rich.table import Table
except ImportError:
    print("Error: 'rich' library not found. Install it with: pip install rich", file=sys.stderr)
    sys.exit(1)

# Suppress SSL warnings for self-signed certs
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# --- Configuration ---
DEFAULT_HOST = "forge"
DEFAULT_DOMAIN = "holthome.net"
DEFAULT_PROMETHEUS_URL = "http://forge.holthome.net:9090"

# Stale threshold in hours
STALE_THRESHOLD_HOURS = 2  # Syncoid runs more frequently than restic backups


def query_prometheus(base_url: str, query: str, api_key: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """Query Prometheus for metrics."""
    url = f"{base_url}/api/v1/query"

    headers = {}
    if api_key:
        headers['X-Api-Key'] = api_key

    try:
        response = requests.get(url, params={'query': query}, headers=headers, timeout=30, verify=False)
        response.raise_for_status()
        data = response.json()
        if data.get('status') == 'success':
            return data.get('data', {})
        return None
    except requests.exceptions.RequestException:
        return None


def get_syncoid_metrics_from_prometheus(base_url: str, api_key: Optional[str] = None) -> List[Dict[str, Any]]:
    """Fetch all syncoid replication metrics from Prometheus."""

    # Syncoid metrics exported by sanoid.nix:
    # - syncoid_replication_status: 0=fail, 1=success, 2=in-progress
    # - syncoid_replication_info: static info (always 1)
    # - syncoid_replication_last_success_timestamp: last success time
    queries = {
        'status': 'syncoid_replication_status',
        'info': 'syncoid_replication_info',
        'last_success': 'syncoid_replication_last_success_timestamp',
    }

    # First get the list of all replication jobs from info metric
    result = query_prometheus(base_url, queries['info'], api_key)
    if not result or 'result' not in result:
        return []

    jobs = {}
    for item in result.get('result', []):
        metric = item.get('metric', {})
        dataset = metric.get('dataset', '')
        if not dataset:
            continue

        unit = metric.get('unit', '')
        target_host = metric.get('target_host', '')
        target_name = metric.get('target_name', '')
        target_location = metric.get('target_location', '')

        # Use dataset as the unique key
        jobs[dataset] = {
            'dataset': dataset,
            'unit': unit,
            'target_host': target_host,
            'target_name': target_name,
            'target_location': target_location,
            'status': None,
            'last_success': None,
            'instance': metric.get('instance', ''),
        }

    # Fetch status metrics
    result = query_prometheus(base_url, queries['status'], api_key)
    if result and 'result' in result:
        for item in result.get('result', []):
            metric = item.get('metric', {})
            dataset = metric.get('dataset', '')
            if dataset in jobs:
                try:
                    jobs[dataset]['status'] = int(float(item.get('value', [0, 0])[1]))
                except (ValueError, TypeError):
                    pass

    # Fetch last success timestamps
    result = query_prometheus(base_url, queries['last_success'], api_key)
    if result and 'result' in result:
        for item in result.get('result', []):
            metric = item.get('metric', {})
            dataset = metric.get('dataset', '')
            if dataset in jobs:
                try:
                    jobs[dataset]['last_success'] = float(item.get('value', [0, 0])[1])
                except (ValueError, TypeError):
                    pass

    return list(jobs.values())


def format_timestamp(ts: Optional[float]) -> str:
    """Format Unix timestamp to human readable."""
    if ts is None:
        return "Never"
    try:
        dt = datetime.fromtimestamp(ts)
        return dt.strftime('%Y-%m-%d %H:%M:%S')
    except Exception:
        return "Unknown"


def time_ago(ts: Optional[float]) -> str:
    """Format timestamp as relative time."""
    if ts is None:
        return "Never"

    now = datetime.now().timestamp()
    diff = now - ts

    if diff < 0:
        return "In future"
    elif diff < 60:
        return "Just now"
    elif diff < 3600:
        return f"{int(diff/60)}m ago"
    elif diff < 86400:
        return f"{int(diff/3600)}h ago"
    else:
        return f"{int(diff/86400)}d ago"


def get_status_display(status: Optional[int], last_success: Optional[float]) -> tuple[str, str, str]:
    """
    Get status display, color, and details.
    Returns: (status_text, color, details)

    Status values: 0=fail, 1=success, 2=in-progress
    """
    now = datetime.now().timestamp()

    if status == 2:
        return "RUNNING", "cyan", "Replication in progress"
    elif status == 0:
        return "FAILED", "red", "Last run failed"
    elif status == 1:
        # Success, but check if stale
        if last_success is not None:
            age_hours = (now - last_success) / 3600
            if age_hours > STALE_THRESHOLD_HOURS:
                return "STALE", "yellow", f"Last success > {STALE_THRESHOLD_HOURS}h ago"
            else:
                return "OK", "green", "Healthy"
        else:
            return "OK", "green", "Healthy (no timestamp)"
    else:
        # Unknown status
        if last_success is not None:
            age_hours = (now - last_success) / 3600
            if age_hours > STALE_THRESHOLD_HOURS:
                return "STALE", "yellow", f"Last success > {STALE_THRESHOLD_HOURS}h ago"
        return "UNKNOWN", "dim", "No status metric"


def shorten_dataset(dataset: str) -> str:
    """Shorten dataset path for display."""
    parts = dataset.split('/')
    if len(parts) > 2:
        # Show pool and last component
        return f"{parts[0]}/.../{parts[-1]}"
    return dataset


# --- Direct verification mode (via SSH) ---

def warmup_ssh_connection(host: str, console: Console, quiet: bool = False) -> bool:
    """Warm up SSH connection to trigger FIDO key PIN prompt."""
    if not quiet:
        console.print(f"[dim]Connecting to {host}...[/dim]")

    try:
        result = subprocess.run(
            ["ssh", host, "echo ok"],
            capture_output=True,
            text=True,
            timeout=60
        )
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        return False
    except Exception:
        return False


def run_ssh_command(host: str, command: str, sudo: bool = True) -> tuple[int, str, str]:
    """Run a command on the remote host via SSH."""
    if sudo:
        command = f"sudo {command}"

    ssh_cmd = ["ssh", host, command]

    try:
        result = subprocess.run(
            ssh_cmd,
            capture_output=True,
            text=True,
            timeout=120
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return 1, "", "Command timed out"
    except Exception as e:
        return 1, "", str(e)


def discover_syncoid_services(host: str) -> List[Dict[str, Any]]:
    """Discover all syncoid services on the remote host."""
    # List all syncoid-*.timer units
    cmd = "systemctl list-units --type=timer --all 'syncoid-*.timer' --no-legend --plain"
    returncode, stdout, stderr = run_ssh_command(host, cmd)

    if returncode != 0:
        return []

    services = []
    for line in stdout.strip().split('\n'):
        if not line.strip():
            continue

        parts = line.split()
        if len(parts) < 1:
            continue

        timer_name = parts[0]
        # Extract service name from timer (syncoid-tank-services-sonarr.timer -> syncoid-tank-services-sonarr)
        service_name = timer_name.replace('.timer', '')

        # Get the service unit status and ExecStart to parse target
        status_cmd = f"systemctl show {service_name}.service --property=ActiveState,SubState,ExecMainExitTimestamp,Result,ExecStart"
        ret, status_out, _ = run_ssh_command(host, status_cmd)

        if ret != 0:
            continue

        props = {}
        for prop_line in status_out.strip().split('\n'):
            if '=' in prop_line:
                key, value = prop_line.split('=', 1)
                props[key] = value

        # Parse dataset from service name (syncoid-tank-services-sonarr -> tank/services/sonarr)
        dataset = service_name.replace('syncoid-', '').replace('-', '/')

        # Parse target from ExecStart
        # Format: { path=/nix/store/.../syncoid ; argv[]=/nix/store/.../syncoid --sshkey ... tank/services/sonarr zfs-replication@nas-1.holthome.net:backup/... ; ... }
        target_host = None
        exec_start = props.get('ExecStart', '')
        if exec_start:
            # Look for user@host:path pattern in the command
            match = re.search(r'(\w+)@([^:\s]+):', exec_start)
            if match:
                target_host = match.group(2)  # Get the host part

        services.append({
            'unit': service_name,
            'dataset': dataset,
            'active_state': props.get('ActiveState', 'unknown'),
            'sub_state': props.get('SubState', 'unknown'),
            'exit_timestamp': props.get('ExecMainExitTimestamp', ''),
            'result': props.get('Result', 'unknown'),
            'target_host': target_host,
        })

    return services


def get_syncoid_verify_data(host: str, console: Console) -> List[Dict[str, Any]]:
    """Get syncoid status by querying systemd units directly via SSH."""
    services = discover_syncoid_services(host)

    results = []
    for svc in services:
        # Determine status from systemd state
        if svc['active_state'] == 'activating':
            status = 2  # In progress
        elif svc['result'] == 'success':
            status = 1  # Success
        else:
            status = 0  # Failed

        # Parse exit timestamp
        # Format: "Fri 2025-11-28 17:00:54 EST"
        last_success = None
        if svc['exit_timestamp'] and svc['result'] == 'success':
            try:
                ts_str = svc['exit_timestamp']
                if ts_str:
                    # Strip timezone suffix (EST, PST, UTC, etc.) and parse
                    # Format: "Fri 2025-11-28 17:00:54 EST" -> "Fri 2025-11-28 17:00:54"
                    parts = ts_str.rsplit(' ', 1)
                    if len(parts) == 2:
                        ts_no_tz = parts[0]
                        dt = datetime.strptime(ts_no_tz, "%a %Y-%m-%d %H:%M:%S")
                        last_success = dt.timestamp()
            except Exception:
                pass

        results.append({
            'dataset': svc['dataset'],
            'unit': svc['unit'],
            'target_host': svc.get('target_host') or 'unknown',
            'target_name': '',
            'target_location': '',
            'status': status,
            'last_success': last_success,
            'systemd_state': f"{svc['active_state']}/{svc['sub_state']}",
        })

    return results


def print_table_output(jobs: List[Dict[str, Any]], console: Console, source: str = "prometheus"):
    """Print formatted table output."""

    if not jobs:
        console.print("[yellow]No syncoid replication jobs found.[/yellow]")
        return

    table = Table(
        title="📦 Syncoid ZFS Replication Status",
        show_header=True,
        header_style="bold magenta"
    )
    table.add_column("Dataset", style="cyan", no_wrap=True)
    table.add_column("Target", style="dim")
    table.add_column("Status", justify="center")
    table.add_column("Last Success", justify="right")
    table.add_column("Details", style="dim")

    # Sort by dataset
    jobs_sorted = sorted(jobs, key=lambda x: x['dataset'])

    stats = {'ok': 0, 'stale': 0, 'failed': 0, 'running': 0, 'unknown': 0}

    for job in jobs_sorted:
        dataset = job['dataset']

        # Build target display
        target_name = job.get('target_name', '')
        target_location = job.get('target_location', '')
        target_host = job.get('target_host', '')

        if target_name and target_location:
            target_display = f"{target_name} ({target_location})"
        elif target_host:
            target_display = target_host
        else:
            target_display = "unknown"

        status_text, color, details = get_status_display(
            job.get('status'),
            job.get('last_success')
        )

        # Track stats
        status_lower = status_text.lower()
        if status_lower in stats:
            stats[status_lower] += 1
        else:
            stats['unknown'] += 1

        # Format last success
        last_success = job.get('last_success')
        last_success_str = time_ago(last_success) if last_success else "Never"

        # Apply color to status
        status_colored = f"[bold {color}]{status_text}[/bold {color}]"

        # Shorten dataset for display
        dataset_short = shorten_dataset(dataset)

        table.add_row(
            dataset_short,
            target_display,
            status_colored,
            last_success_str,
            details
        )

    console.print(table)

    # Summary
    total = len(jobs)
    console.print()
    console.print(f"[dim]Total: {total} | OK: {stats['ok']} | Running: {stats['running']} | Stale: {stats['stale']} | Failed: {stats['failed']}[/dim]")
    console.print(f"[dim]Data source: {source} | Stale threshold: {STALE_THRESHOLD_HOURS} hours[/dim]")


def print_json_output(jobs: List[Dict[str, Any]], host: str, mode: str):
    """Print JSON output for scripting."""

    stats = {'ok': 0, 'stale': 0, 'failed': 0, 'running': 0, 'unknown': 0}

    output_jobs = []
    for job in jobs:
        status_text, _, details = get_status_display(
            job.get('status'),
            job.get('last_success')
        )

        status_lower = status_text.lower()
        if status_lower in stats:
            stats[status_lower] += 1

        output_jobs.append({
            'dataset': job['dataset'],
            'unit': job.get('unit', ''),
            'target_host': job.get('target_host', ''),
            'target_name': job.get('target_name', ''),
            'target_location': job.get('target_location', ''),
            'status': job.get('status'),
            'status_text': status_text,
            'last_success': job.get('last_success'),
            'details': details,
        })

    output = {
        'host': host,
        'mode': mode,
        'stale_threshold_hours': STALE_THRESHOLD_HOURS,
        'jobs': output_jobs,
        'summary': {
            'total': len(jobs),
            'ok': stats['ok'],
            'running': stats['running'],
            'stale': stats['stale'],
            'failed': stats['failed'],
            'healthy': stats['ok'] + stats['running'],
        }
    }

    print(json.dumps(output, indent=2))


def main():
    """Main function to query data and render output."""
    parser = argparse.ArgumentParser(
        description="List Syncoid ZFS replication status",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    syncoid-list                          # List all replications via Prometheus
    syncoid-list --dataset sonarr         # Filter by dataset name (partial match)
    syncoid-list --target nas-1           # Filter by target host
    syncoid-list --verify                 # Query systemd directly (slower, validates)
    syncoid-list --json                   # JSON output for scripting
    syncoid-list --json | jq '.summary'   # Get just the summary
        """
    )
    parser.add_argument(
        "--host",
        default=os.getenv("SYNCOID_HOST", DEFAULT_HOST),
        help=f"Target host (default: {DEFAULT_HOST})"
    )
    parser.add_argument(
        "--domain",
        default=os.getenv("NIXOS_DOMAIN", DEFAULT_DOMAIN),
        help=f"Domain suffix (default: {DEFAULT_DOMAIN})"
    )
    parser.add_argument(
        "--prometheus-url",
        default=os.getenv("PROMETHEUS_URL", DEFAULT_PROMETHEUS_URL),
        help=f"Prometheus server URL (default: {DEFAULT_PROMETHEUS_URL})"
    )
    parser.add_argument(
        "--api-key",
        default=os.getenv("PROMETHEUS_API_KEY"),
        help="API key for Prometheus authentication"
    )
    parser.add_argument(
        "--dataset",
        help="Filter by dataset name (partial match)"
    )
    parser.add_argument(
        "--target",
        help="Filter by target host (partial match)"
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Query systemd directly via SSH instead of Prometheus"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output in JSON format"
    )
    args = parser.parse_args()

    console = Console()
    fqdn = f"{args.host}.{args.domain}"

    # Get data based on mode
    if args.verify:
        # Direct verification via SSH
        if not warmup_ssh_connection(fqdn, console, quiet=args.json):
            if args.json:
                print(json.dumps({"error": f"Failed to connect to {fqdn}"}))
            else:
                console.print(f"[red]Failed to connect to {fqdn}[/red]")
            return 1

        jobs = get_syncoid_verify_data(fqdn, console)
        source = f"ssh://{fqdn}"
        mode = "verify"
    else:
        # Prometheus mode (default)
        if not args.api_key:
            console.print("[yellow]Warning: PROMETHEUS_API_KEY not set. Some endpoints may require authentication.[/yellow]")

        jobs = get_syncoid_metrics_from_prometheus(args.prometheus_url, args.api_key)
        source = args.prometheus_url
        mode = "prometheus"

    # Apply filters
    if args.dataset:
        jobs = [j for j in jobs if args.dataset.lower() in j['dataset'].lower()]

    if args.target:
        jobs = [j for j in jobs if args.target.lower() in j.get('target_host', '').lower()]

    # Output
    if args.json:
        print_json_output(jobs, fqdn, mode)
    else:
        if not jobs:
            console.print("[yellow]No syncoid replication jobs found.[/yellow]")
            console.print(f"[dim]Data source: {source}[/dim]")
            return 1

        print_table_output(jobs, console, source)

    return 0


if __name__ == "__main__":
    sys.exit(main())
