#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
A CLI tool for listing Restic backup snapshots across all enabled services.

Default mode: Query Prometheus for backup metrics (fast, single HTTP call)
Verify mode: Query each repository directly via restic CLI (slower, validates data)

Usage:
    backup-list [--host HOST] [--service NAME] [--repo NAME] [--verify] [--json]

Environment Variables:
    NIXOS_DOMAIN: Domain suffix (default: holthome.net)
"""

import argparse
import json
import os
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
    from rich.panel import Panel
    from rich.text import Text
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


def get_backup_metrics_from_prometheus(base_url: str, api_key: Optional[str] = None) -> List[Dict[str, Any]]:
    """Fetch all backup metrics from Prometheus."""

    # Query for backup status and related metrics
    # We'll get all restic_backup_* metrics and aggregate by backup_job
    queries = {
        'status': 'restic_backup_status',
        'last_success': 'restic_backup_last_success_timestamp',
        'duration': 'restic_backup_duration_seconds',
        'files': 'restic_backup_files_total',
        'size': 'restic_backup_size_bytes',
        'snapshots': 'restic_backup_snapshots_total',
        'healthy': 'restic_backup_repo_healthy',
    }

    # First get the list of all backup jobs from status metric
    result = query_prometheus(base_url, queries['status'], api_key)
    if not result or 'result' not in result:
        return []

    jobs = {}
    for item in result.get('result', []):
        metric = item.get('metric', {})
        job_name = metric.get('backup_job', '')
        if not job_name:
            continue

        jobs[job_name] = {
            'job_name': job_name,
            'repository': metric.get('repository', ''),
            'repository_name': metric.get('repository_name', ''),
            'repository_location': metric.get('repository_location', ''),
            'hostname': metric.get('hostname', ''),
            'status': int(float(item.get('value', [0, 0])[1])),
            'last_success': None,
            'duration': None,
            'files': None,
            'size': None,
            'snapshots': None,
            'healthy': None,
        }

    # Now fetch additional metrics
    for metric_name, query in queries.items():
        if metric_name == 'status':
            continue  # Already fetched

        result = query_prometheus(base_url, query, api_key)
        if not result or 'result' not in result:
            continue

        for item in result.get('result', []):
            metric = item.get('metric', {})
            job_name = metric.get('backup_job', '')
            if job_name not in jobs:
                continue

            value = item.get('value', [0, 0])[1]
            try:
                if metric_name == 'last_success':
                    jobs[job_name]['last_success'] = float(value)
                elif metric_name == 'duration':
                    jobs[job_name]['duration'] = float(value)
                elif metric_name == 'files':
                    jobs[job_name]['files'] = int(float(value))
                elif metric_name == 'size':
                    jobs[job_name]['size'] = int(float(value))
                elif metric_name == 'snapshots':
                    jobs[job_name]['snapshots'] = int(float(value))
                elif metric_name == 'healthy':
                    jobs[job_name]['healthy'] = int(float(value)) == 1
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


def format_size(size_bytes: Optional[int]) -> str:
    """Format bytes to human readable size."""
    if size_bytes is None:
        return "-"

    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if abs(size_bytes) < 1024.0:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.1f} PB"


def format_duration(seconds: Optional[float]) -> str:
    """Format seconds to human readable duration."""
    if seconds is None:
        return "-"

    if seconds < 60:
        return f"{seconds:.0f}s"
    elif seconds < 3600:
        return f"{seconds/60:.1f}m"
    else:
        return f"{seconds/3600:.1f}h"


def time_ago(ts: Optional[float]) -> str:
    """Format timestamp as relative time."""
    if ts is None:
        return "Never"

    now = datetime.now().timestamp()
    diff = now - ts

    if diff < 60:
        return "Just now"
    elif diff < 3600:
        return f"{int(diff/60)}m ago"
    elif diff < 86400:
        return f"{int(diff/3600)}h ago"
    else:
        return f"{int(diff/86400)}d ago"


# --- Direct verification mode (via SSH + restic) ---

def warmup_ssh_connection(host: str, console: Console, quiet: bool = False) -> bool:
    """
    Warm up SSH connection to trigger FIDO key PIN prompt.

    FIDO/hardware keys often need user interaction (PIN) on first connection.
    This warmup ensures the key is unlocked before we start the real work,
    avoiding timeouts on the first actual command.
    """
    if not quiet:
        console.print(f"[dim]Connecting to {host}...[/dim]")

    try:
        # Simple command that requires minimal time but triggers auth
        result = subprocess.run(
            ["ssh", host, "echo ok"],
            capture_output=True,
            text=True,
            timeout=60  # Longer timeout for PIN entry
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


def discover_restic_services(host: str) -> List[str]:
    """Discover all restic backup services on the remote host."""
    cmd = "systemctl list-units --all --type=service 'restic-backup-*.service' --no-pager --plain | awk '{print $1}' | grep -E '^restic-backup-.*\\.service$'"

    returncode, stdout, stderr = run_ssh_command(host, cmd, sudo=False)

    if returncode != 0 or not stdout.strip():
        return []

    return [s.strip() for s in stdout.strip().split('\n') if s.strip()]


def get_service_env(host: str, service: str) -> Dict[str, str]:
    """Get environment variables from a systemd service."""
    cmd = f"systemctl show {service} -p Environment -p EnvironmentFile --value"

    returncode, stdout, stderr = run_ssh_command(host, cmd, sudo=False)

    if returncode != 0:
        return {}

    env = {}
    lines = stdout.strip().split('\n')

    if len(lines) >= 1 and lines[0]:
        for pair in lines[0].split():
            if '=' in pair:
                key, value = pair.split('=', 1)
                env[key] = value

    if len(lines) >= 2 and lines[1]:
        env['_ENV_FILE'] = lines[1].lstrip('-')

    return env


def get_repo_name(url: str) -> str:
    """Determine repository name from URL."""
    if url.startswith('/mnt/nas-backup'):
        return "nas-primary"
    elif url.startswith('s3:') and 'r2.cloudflarestorage.com' in url:
        return "r2-offsite"
    elif url.startswith('s3:'):
        return "s3-remote"
    elif url.startswith('/mnt/'):
        return os.path.basename(os.path.dirname(url))
    else:
        return "unknown"


def verify_snapshots(host: str, job_name: str, env: Dict[str, str], limit: int) -> Optional[Dict[str, Any]]:
    """Verify snapshots by directly querying restic."""
    repo_url = env.get('RESTIC_REPOSITORY', '')
    password_file = env.get('RESTIC_PASSWORD_FILE', '')
    cache_dir = env.get('RESTIC_CACHE_DIR', '/var/cache/restic')
    env_file = env.get('_ENV_FILE', '')

    if not repo_url or not password_file:
        return None

    repo_name = get_repo_name(repo_url)

    env_prefix = f"RESTIC_REPOSITORY='{repo_url}' RESTIC_PASSWORD_FILE='{password_file}' RESTIC_CACHE_DIR='{cache_dir}'"

    if env_file:
        env_prefix = f"source '{env_file}' && {env_prefix}"

    # Extract the actual service name from the job name
    # Job names are like "service-autobrr" but tags are just "autobrr"
    tag_name = job_name
    if tag_name.startswith('service-'):
        tag_name = tag_name[8:]  # Remove "service-" prefix

    # Filter by tag matching the service name
    restic_cmd = f"nix-shell -p restic jq --run \"{env_prefix} restic snapshots --json --tag '{tag_name}' --latest {limit}\""

    returncode, stdout, stderr = run_ssh_command(host, restic_cmd)

    if returncode != 0:
        return {
            'job_name': job_name,
            'repo_name': repo_name,
            'repo_url': repo_url,
            'error': stderr or 'Failed to list snapshots',
            'snapshots': [],
            'verified': False
        }

    try:
        snapshots = json.loads(stdout)
    except json.JSONDecodeError:
        snapshots = []

    return {
        'job_name': job_name,
        'repo_name': repo_name,
        'repo_url': repo_url,
        'snapshots': snapshots,
        'error': None,
        'verified': True
    }


def format_snapshot_time(time_str: str) -> str:
    """Format ISO timestamp to human readable."""
    try:
        dt = datetime.fromisoformat(time_str.replace('Z', '+00:00'))
        return dt.strftime('%Y-%m-%d %H:%M:%S')
    except Exception:
        return time_str


# --- Main ---

def main():
    """Main function to list backup snapshots."""
    parser = argparse.ArgumentParser(
        description="List Restic backup snapshots for all enabled services",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Modes:
  Default:    Query Prometheus for cached metrics (fast)
  --verify:   Query each repository directly via restic (slower, validates data)

Examples:
  backup-list                        # List from Prometheus metrics
  backup-list --verify               # Verify by querying restic directly
  backup-list --service sonarr       # Filter by service name
  backup-list --repo nas-primary     # Filter by repository
  backup-list --json                 # JSON output for scripting

Environment Variables:
  PROMETHEUS_API_KEY:  API key for Prometheus authentication
  NIXOS_DOMAIN:        Domain suffix (default: holthome.net)
  BACKUP_HOST:         Target host (default: forge)
"""
    )
    parser.add_argument(
        "--host",
        default=os.getenv("BACKUP_HOST", DEFAULT_HOST),
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
        help=f"Prometheus URL (default: {DEFAULT_PROMETHEUS_URL})"
    )
    parser.add_argument(
        "--api-key",
        default=os.getenv("PROMETHEUS_API_KEY"),
        help="API key for Prometheus (or set PROMETHEUS_API_KEY)"
    )
    parser.add_argument(
        "--service", "-s",
        default=None,
        help="Filter by service name (partial match)"
    )
    parser.add_argument(
        "--repo", "-r",
        default=None,
        help="Filter by repository name"
    )
    parser.add_argument(
        "--verify", "-v",
        action="store_true",
        help="Verify by querying restic directly (slower but validates data)"
    )
    parser.add_argument(
        "--limit", "-n",
        type=int,
        default=10,
        help="Maximum snapshots per service in verify mode (default: 10)"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Output in JSON format"
    )
    parser.add_argument(
        "--quiet", "-q",
        action="store_true",
        help="Minimal output"
    )

    args = parser.parse_args()

    console = Console()
    full_host = f"{args.host}.{args.domain}"

    # Prometheus URL (either from arg or default)
    prometheus_url = args.prometheus_url

    if args.verify:
        # --- Verify mode: Query restic directly via SSH ---
        if not args.quiet and not args.json_output:
            console.print(f"[yellow]Verify mode:[/yellow] Querying restic directly on {full_host}...")
            console.print("[dim]This may take a while...[/dim]")

        # Warm up SSH connection to trigger FIDO key PIN prompt
        if not warmup_ssh_connection(full_host, console, quiet=args.quiet or args.json_output):
            if args.json_output:
                print(json.dumps({"error": "Failed to connect to remote host", "services": [], "mode": "verify"}))
            else:
                console.print(f"[red]Failed to connect to {full_host}[/red]")
            return 1

        services = discover_restic_services(full_host)

        if not services:
            if args.json_output:
                print(json.dumps({"error": "No Restic backup services found", "services": [], "mode": "verify"}))
            else:
                console.print(f"[yellow]No Restic backup services found on {full_host}[/yellow]")
            return 1

        if not args.quiet and not args.json_output:
            console.print(f"[dim]Found {len(services)} backup services[/dim]")

        results = []

        for service in services:
            job_name = service.replace('restic-backup-', '').replace('.service', '')

            if args.service and args.service.lower() not in job_name.lower():
                continue

            env = get_service_env(full_host, service)
            if not env:
                continue

            repo_url = env.get('RESTIC_REPOSITORY', '')
            repo_name = get_repo_name(repo_url)

            if args.repo and args.repo.lower() not in repo_name.lower():
                continue

            if not args.quiet and not args.json_output:
                console.print(f"[dim]  Verifying {job_name}...[/dim]")

            result = verify_snapshots(full_host, job_name, env, args.limit)
            if result:
                results.append(result)

        if args.json_output:
            output = {
                "host": full_host,
                "mode": "verify",
                "services": results,
                "summary": {
                    "total_services": len(results),
                    "verified_services": len([r for r in results if r.get('verified')]),
                    "total_snapshots": sum(len(r['snapshots']) for r in results if isinstance(r['snapshots'], list))
                }
            }
            print(json.dumps(output, indent=2))
        else:
            for result in results:
                job_name = result['job_name']
                repo_name = result['repo_name']

                header = Text()
                header.append(job_name, style="bold green")
                header.append(f"  [dim](Repository: {repo_name})[/dim]")

                if result.get('error'):
                    console.print(Panel(
                        f"[red]Error: {result['error']}[/red]",
                        title=str(header),
                        border_style="red"
                    ))
                    continue

                snapshots = result['snapshots']

                if not snapshots:
                    console.print(Panel(
                        "[dim]No snapshots found[/dim]",
                        title=str(header),
                        border_style="cyan"
                    ))
                    continue

                table = Table(show_header=True, header_style="bold magenta", box=None)
                table.add_column("ID", style="cyan", no_wrap=True)
                table.add_column("Time", style="green")
                table.add_column("Host", style="dim")
                table.add_column("Tags", style="yellow")

                for snap in snapshots:
                    snap_id = snap.get('short_id', snap.get('id', '')[:8])
                    time = format_snapshot_time(snap.get('time', ''))
                    hostname = snap.get('hostname', '')
                    tags = ', '.join(snap.get('tags', []))

                    table.add_row(snap_id, time, hostname, tags)

                console.print(Panel(
                    table,
                    title=str(header),
                    border_style="cyan",
                    subtitle="[green]✓ Verified[/green]"
                ))

            if not args.quiet:
                console.print()
                console.print("[bold]Summary[/bold]")
                console.print(f"  Services verified: [green]{len([r for r in results if r.get('verified')])}[/green] / {len(results)}")
                console.print("  Mode: [yellow]Direct verification[/yellow]")

    else:
        # --- Default mode: Query Prometheus ---
        if not args.quiet and not args.json_output:
            console.print(f"[dim]Querying Prometheus metrics from {prometheus_url}...[/dim]")

        metrics = get_backup_metrics_from_prometheus(prometheus_url, args.api_key)

        if not metrics:
            if args.json_output:
                print(json.dumps({"error": "No backup metrics found in Prometheus", "services": [], "mode": "prometheus"}))
            else:
                console.print("[yellow]No backup metrics found in Prometheus[/yellow]")
                console.print("[dim]Try --verify to query restic directly[/dim]")
            return 1

        # Apply filters
        if args.service:
            metrics = [m for m in metrics if args.service.lower() in m['job_name'].lower()]

        if args.repo:
            metrics = [m for m in metrics if args.repo.lower() in m.get('repository_name', '').lower()]

        if args.json_output:
            output = {
                "host": full_host,
                "mode": "prometheus",
                "services": metrics,
                "summary": {
                    "total_services": len(metrics),
                    "healthy_services": len([m for m in metrics if m.get('healthy')]),
                    "total_snapshots": sum(m.get('snapshots', 0) or 0 for m in metrics)
                }
            }
            print(json.dumps(output, indent=2))
        else:
            # Create summary table
            table = Table(
                title=f"Backup Status - {full_host}",
                show_header=True,
                header_style="bold magenta"
            )
            table.add_column("Service", style="cyan", no_wrap=True)
            table.add_column("Repository", style="dim")
            table.add_column("Status", justify="center")
            table.add_column("Last Backup", style="green")
            table.add_column("Duration", justify="right")
            table.add_column("Snapshots", justify="right")
            table.add_column("Size Added", justify="right")
            table.add_column("Healthy", justify="center")

            for m in sorted(metrics, key=lambda x: x['job_name']):
                status = "[green]✓[/green]" if m['status'] == 1 else "[red]✗[/red]"
                healthy = "[green]✓[/green]" if m.get('healthy') else "[red]✗[/red]" if m.get('healthy') is False else "[dim]-[/dim]"

                table.add_row(
                    m['job_name'],
                    m.get('repository_name', '-'),
                    status,
                    time_ago(m.get('last_success')),
                    format_duration(m.get('duration')),
                    str(m.get('snapshots', '-') or '-'),
                    format_size(m.get('size')),
                    healthy
                )

            console.print()
            console.print(table)

            if not args.quiet:
                console.print()
                console.print("[dim]Tip: Use --verify to validate data directly from restic repositories[/dim]")

    return 0


if __name__ == "__main__":
    sys.exit(main())
