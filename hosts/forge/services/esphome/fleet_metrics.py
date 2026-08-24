#!/usr/bin/env python3
"""Export ESPHome fleet health through node_exporter's textfile collector."""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import functools
import ipaddress
import json
import math
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from collections import defaultdict
from collections.abc import Callable, Mapping, Sequence
from typing import Any

NODE_NAME_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")
DOMAIN_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$")
MONITORED_TIERS = frozenset({"critical", "standard"})
ALL_TIERS = MONITORED_TIERS | {"ignore"}
RESOLVER_LOCK = threading.Lock()


@dataclasses.dataclass(frozen=True)
class FleetPolicy:
    default_tier: str
    critical: frozenset[str]
    ignore: frozenset[str]

    def tier_for(self, node_name: str) -> str:
        if node_name in self.ignore:
            return "ignore"
        if node_name in self.critical:
            return "critical"
        return self.default_tier


@dataclasses.dataclass(frozen=True)
class FleetNode:
    name: str
    friendly_name: str
    configurations: tuple[str, ...]
    api_enabled: bool
    uses_deep_sleep: bool
    dashboard_state: str
    dashboard_ip: str | None

    @property
    def configuration_count(self) -> int:
        return len(self.configurations)


@dataclasses.dataclass(frozen=True)
class ProbeResult:
    node_name: str
    tier: str
    dns_resolves: bool
    target_source: str
    api_up: bool
    duration_seconds: float | None


Resolver = Callable[[str, int], str | None]
Connector = Callable[[str, int, float], tuple[bool, float]]


def _require_string_list(value: Any, field_name: str) -> frozenset[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"policy field {field_name!r} must be a list of strings")
    invalid_names = sorted(
        item for item in value if not NODE_NAME_PATTERN.fullmatch(item)
    )
    if invalid_names:
        raise ValueError(
            f"policy field {field_name!r} has invalid node names: {invalid_names}"
        )
    return frozenset(value)


def parse_policy(document: Any) -> FleetPolicy:
    if not isinstance(document, dict):
        raise ValueError("policy must be a JSON object")

    default_tier = document.get("default_tier", "standard")
    if default_tier not in MONITORED_TIERS:
        raise ValueError(f"default_tier must be one of {sorted(MONITORED_TIERS)}")

    critical = _require_string_list(document.get("critical", []), "critical")
    ignore = _require_string_list(document.get("ignore", []), "ignore")
    overlap = sorted(critical & ignore)
    if overlap:
        raise ValueError(f"nodes cannot be both critical and ignored: {overlap}")

    return FleetPolicy(default_tier=default_tier, critical=critical, ignore=ignore)


def load_policy(path: pathlib.Path) -> FleetPolicy:
    with path.open(encoding="utf-8") as policy_file:
        return parse_policy(json.load(policy_file))


def fetch_inventory(url: str, timeout_seconds: float) -> Any:
    request = urllib.request.Request(
        url, headers={"User-Agent": "esphome-fleet-metrics/1"}
    )
    with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
        payload = response.read(10_000_001)
    if len(payload) > 10_000_000:
        raise ValueError("ESPHome inventory response exceeded 10 MB")
    return json.loads(payload)


def _valid_ip(value: Any) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        return None


def _select_dashboard_ip(rows: Sequence[Mapping[str, Any]]) -> str | None:
    candidates: list[str] = []
    for row in rows:
        direct_ip = _valid_ip(row.get("ip"))
        if direct_ip is not None:
            candidates.append(direct_ip)
        addresses = row.get("ip_addresses", [])
        if isinstance(addresses, list):
            candidates.extend(
                valid_ip
                for address in addresses
                if (valid_ip := _valid_ip(address)) is not None
            )
    return sorted(set(candidates))[0] if candidates else None


def _select_dashboard_state(rows: Sequence[Mapping[str, Any]]) -> str:
    states = {
        str(row.get("state", "unknown")).lower()
        for row in rows
        if row.get("state") is not None
    }
    for preferred_state in ("online", "offline", "unknown"):
        if preferred_state in states:
            return preferred_state
    return sorted(states)[0] if states else "unknown"


def build_nodes(document: Any) -> list[FleetNode]:
    if not isinstance(document, dict) or not isinstance(
        document.get("configured"), list
    ):
        raise ValueError("ESPHome inventory must contain a configured array")
    if not document["configured"]:
        raise ValueError("ESPHome inventory contains no configured devices")

    grouped_rows: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for index, raw_row in enumerate(document["configured"]):
        if not isinstance(raw_row, dict):
            raise ValueError(f"configured item {index} must be an object")
        node_name = raw_row.get("name")
        if not isinstance(node_name, str) or not NODE_NAME_PATTERN.fullmatch(node_name):
            raise ValueError(
                f"configured item {index} has invalid node name {node_name!r}"
            )
        grouped_rows[node_name].append(raw_row)

    nodes: list[FleetNode] = []
    for node_name, unsorted_rows in sorted(grouped_rows.items()):
        rows = sorted(unsorted_rows, key=lambda row: str(row.get("configuration", "")))
        configurations = tuple(
            sorted(
                {
                    str(row["configuration"])
                    for row in rows
                    if isinstance(row.get("configuration"), str)
                    and row["configuration"]
                }
            )
        )
        friendly_names = sorted(
            {
                str(row["friendly_name"])
                for row in rows
                if isinstance(row.get("friendly_name"), str) and row["friendly_name"]
            }
        )
        nodes.append(
            FleetNode(
                name=node_name,
                friendly_name=friendly_names[0] if friendly_names else node_name,
                configurations=configurations or ("unknown",),
                api_enabled=any(row.get("api_enabled") is True for row in rows),
                uses_deep_sleep=any(row.get("uses_deep_sleep") is True for row in rows),
                dashboard_state=_select_dashboard_state(rows),
                dashboard_ip=_select_dashboard_ip(rows),
            )
        )
    return nodes


def command_resolver(
    host: str,
    port: int,
    *,
    command: str,
    timeout_seconds: float,
) -> str | None:
    del port
    try:
        with RESOLVER_LOCK:
            result = subprocess.run(
                [command, "ahostsv4", host],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=timeout_seconds,
            )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        fields = line.split(maxsplit=1)
        if fields and (resolved_ip := _valid_ip(fields[0])) is not None:
            return resolved_ip
    return None


def socket_connector(
    host: str, port: int, timeout_seconds: float
) -> tuple[bool, float]:
    started_at = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout_seconds):
            return True, time.monotonic() - started_at
    except OSError:
        return False, time.monotonic() - started_at


def probe_node(
    node: FleetNode,
    tier: str,
    domain: str,
    port: int,
    timeout_seconds: float,
    resolver: Resolver,
    connector: Connector = socket_connector,
) -> ProbeResult:
    fqdn = f"{node.name}.{domain}"
    resolved_ip = resolver(fqdn, port)
    dns_resolves = resolved_ip is not None
    if resolved_ip is not None:
        target = resolved_ip
        target_source = "dns"
    elif node.dashboard_ip is not None:
        target = node.dashboard_ip
        target_source = "dashboard_ip"
    else:
        return ProbeResult(
            node_name=node.name,
            tier=tier,
            dns_resolves=False,
            target_source="none",
            api_up=False,
            duration_seconds=None,
        )

    api_up, duration_seconds = connector(target, port, timeout_seconds)
    return ProbeResult(
        node_name=node.name,
        tier=tier,
        dns_resolves=dns_resolves,
        target_source=target_source,
        api_up=api_up,
        duration_seconds=duration_seconds,
    )


def _escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def _format_value(value: bool | int | float) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int):
        return str(value)
    if not math.isfinite(value):
        raise ValueError(f"metric value must be finite, got {value!r}")
    return format(value, ".12g")


def metric_line(
    metric_name: str,
    value: bool | int | float,
    labels: Mapping[str, str] | None = None,
) -> str:
    label_text = ""
    if labels:
        rendered_labels = ",".join(
            f'{label_name}="{_escape_label(label_value)}"'
            for label_name, label_value in sorted(labels.items())
        )
        label_text = f"{{{rendered_labels}}}"
    return f"{metric_name}{label_text} {_format_value(value)}"


def _metric_header(
    metric_name: str, help_text: str, metric_type: str = "gauge"
) -> list[str]:
    return [
        f"# HELP {metric_name} {help_text}",
        f"# TYPE {metric_name} {metric_type}",
    ]


def collect_probe_results(
    nodes: Sequence[FleetNode],
    policy: FleetPolicy,
    domain: str,
    port: int,
    timeout_seconds: float,
    workers: int,
    resolver: Resolver,
    connector: Connector = socket_connector,
) -> list[ProbeResult]:
    probe_candidates = [
        (node, policy.tier_for(node.name))
        for node in nodes
        if node.api_enabled
        and not node.uses_deep_sleep
        and policy.tier_for(node.name) != "ignore"
    ]
    if not probe_candidates:
        return []

    results: list[ProbeResult] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [
            executor.submit(
                probe_node,
                node,
                tier,
                domain,
                port,
                timeout_seconds,
                resolver,
                connector,
            )
            for node, tier in probe_candidates
        ]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())
    return sorted(results, key=lambda result: result.node_name)


def render_fleet_metrics(
    nodes: Sequence[FleetNode],
    policy: FleetPolicy,
    probe_results: Sequence[ProbeResult],
    collected_at: int,
) -> str:
    lines: list[str] = []
    headers = [
        (
            "esphome_fleet_last_success_timestamp_seconds",
            "Unix timestamp of the last successful fleet collection",
        ),
        ("esphome_fleet_device_info", "ESPHome device inventory metadata"),
        (
            "esphome_fleet_config_count",
            "Number of active ESPHome configuration files per node",
        ),
        (
            "esphome_fleet_eligible",
            "Whether the node is eligible for continuous API monitoring",
        ),
        (
            "esphome_fleet_dashboard_online",
            "Whether ESPHome Dashboard currently reports the node online",
        ),
        ("esphome_fleet_dns_resolves", "Whether the stable internal DNS name resolves"),
        (
            "esphome_fleet_api_up",
            "Whether TCP connection to the ESPHome native API succeeded",
        ),
        (
            "esphome_fleet_connect_duration_seconds",
            "TCP connection duration to the ESPHome native API",
        ),
        (
            "esphome_fleet_devices_total",
            "Number of unique ESPHome nodes by monitoring tier",
        ),
        (
            "esphome_fleet_eligible_total",
            "Number of nodes eligible for continuous API monitoring",
        ),
        (
            "esphome_fleet_probe_nodes_total",
            "Number of nodes included in this probe run",
        ),
        (
            "esphome_fleet_api_up_total",
            "Number of nodes whose ESPHome native API accepted a connection",
        ),
        (
            "esphome_fleet_unresolved_targets_total",
            "Number of probed nodes without stable internal DNS",
        ),
        (
            "esphome_fleet_duplicate_nodes_total",
            "Number of node names backed by multiple active configs",
        ),
        (
            "esphome_fleet_policy_orphans_total",
            "Number of explicitly classified policy nodes missing from inventory",
        ),
    ]
    for metric_name, help_text in headers:
        lines.extend(_metric_header(metric_name, help_text))

    lines.append(
        metric_line("esphome_fleet_last_success_timestamp_seconds", collected_at)
    )

    tier_counts = {tier: 0 for tier in sorted(ALL_TIERS)}
    eligible_count = 0
    duplicate_count = 0
    discovered_names = {node.name for node in nodes}

    for node in sorted(nodes, key=lambda item: item.name):
        tier = policy.tier_for(node.name)
        tier_counts[tier] += 1
        eligible = node.api_enabled and not node.uses_deep_sleep and tier != "ignore"
        eligible_count += int(eligible)
        duplicate_count += int(node.configuration_count > 1)
        common_labels = {"node": node.name, "tier": tier}
        lines.append(
            metric_line(
                "esphome_fleet_device_info",
                1,
                {
                    **common_labels,
                    "friendly_name": node.friendly_name,
                    "dashboard_state": node.dashboard_state,
                },
            )
        )
        lines.append(
            metric_line(
                "esphome_fleet_config_count",
                node.configuration_count,
                {"node": node.name},
            )
        )
        lines.append(metric_line("esphome_fleet_eligible", eligible, common_labels))
        lines.append(
            metric_line(
                "esphome_fleet_dashboard_online",
                node.dashboard_state == "online",
                common_labels,
            )
        )

    for result in probe_results:
        labels = {
            "node": result.node_name,
            "tier": result.tier,
            "target_source": result.target_source,
        }
        lines.append(
            metric_line("esphome_fleet_dns_resolves", result.dns_resolves, labels)
        )
        lines.append(metric_line("esphome_fleet_api_up", result.api_up, labels))
        if result.duration_seconds is not None:
            lines.append(
                metric_line(
                    "esphome_fleet_connect_duration_seconds",
                    result.duration_seconds,
                    labels,
                )
            )

    for tier, count in sorted(tier_counts.items()):
        lines.append(metric_line("esphome_fleet_devices_total", count, {"tier": tier}))
    policy_names = policy.critical | policy.ignore
    policy_orphans = policy_names - discovered_names
    lines.extend(
        [
            metric_line("esphome_fleet_eligible_total", eligible_count),
            metric_line("esphome_fleet_probe_nodes_total", len(probe_results)),
            metric_line(
                "esphome_fleet_api_up_total",
                sum(result.api_up for result in probe_results),
            ),
            metric_line(
                "esphome_fleet_unresolved_targets_total",
                sum(not result.dns_resolves for result in probe_results),
            ),
            metric_line("esphome_fleet_duplicate_nodes_total", duplicate_count),
            metric_line("esphome_fleet_policy_orphans_total", len(policy_orphans)),
        ]
    )
    return "\n".join(lines) + "\n"


def render_collector_metrics(
    success: bool, attempted_at: int, duration_seconds: float
) -> str:
    lines: list[str] = []
    for metric_name, help_text in (
        (
            "esphome_fleet_collector_success",
            "Whether the latest fleet collection completed successfully",
        ),
        (
            "esphome_fleet_last_attempt_timestamp_seconds",
            "Unix timestamp of the latest fleet collection attempt",
        ),
        (
            "esphome_fleet_collector_duration_seconds",
            "Duration of the latest fleet collection attempt",
        ),
    ):
        lines.extend(_metric_header(metric_name, help_text))
    lines.extend(
        [
            metric_line("esphome_fleet_collector_success", success),
            metric_line("esphome_fleet_last_attempt_timestamp_seconds", attempted_at),
            metric_line("esphome_fleet_collector_duration_seconds", duration_seconds),
        ]
    )
    return "\n".join(lines) + "\n"


def atomic_write(path: pathlib.Path, content: str) -> None:
    temporary_path: pathlib.Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as temporary_file:
            temporary_path = pathlib.Path(temporary_file.name)
            temporary_file.write(content)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        temporary_path.chmod(0o644)
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def parse_arguments(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--devices-url", default="http://127.0.0.1:6052/devices")
    parser.add_argument("--domain", required=True)
    parser.add_argument("--policy-file", type=pathlib.Path, required=True)
    parser.add_argument("--metrics-file", type=pathlib.Path, required=True)
    parser.add_argument("--status-file", type=pathlib.Path, required=True)
    parser.add_argument("--port", type=int, default=6053)
    parser.add_argument("--inventory-timeout", type=float, default=10.0)
    parser.add_argument("--resolver-command", required=True)
    parser.add_argument("--resolver-timeout", type=float, default=1.0)
    parser.add_argument("--probe-timeout", type=float, default=2.0)
    parser.add_argument("--workers", type=int, default=8)
    return parser.parse_args(arguments)


def run(arguments: Sequence[str] | None = None) -> int:
    options = parse_arguments(arguments)
    if not DOMAIN_PATTERN.fullmatch(options.domain):
        print(f"error: invalid domain {options.domain!r}", file=sys.stderr)
        return 2
    if not 1 <= options.port <= 65535:
        print("error: port must be between 1 and 65535", file=sys.stderr)
        return 2
    if (
        options.inventory_timeout <= 0
        or options.resolver_timeout <= 0
        or options.probe_timeout <= 0
    ):
        print("error: timeouts must be positive", file=sys.stderr)
        return 2
    if options.workers <= 0:
        print("error: workers must be positive", file=sys.stderr)
        return 2

    started_at = time.monotonic()
    attempted_at = int(time.time())
    collection_succeeded = False
    exit_code = 0
    try:
        policy = load_policy(options.policy_file)
        inventory = fetch_inventory(options.devices_url, options.inventory_timeout)
        nodes = build_nodes(inventory)
        resolver = functools.partial(
            command_resolver,
            command=options.resolver_command,
            timeout_seconds=options.resolver_timeout,
        )
        probe_results = collect_probe_results(
            nodes,
            policy,
            options.domain,
            options.port,
            options.probe_timeout,
            options.workers,
            resolver,
        )
        fleet_metrics = render_fleet_metrics(nodes, policy, probe_results, attempted_at)
        atomic_write(options.metrics_file, fleet_metrics)
        collection_succeeded = True
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: ESPHome fleet collection failed: {error}", file=sys.stderr)
        exit_code = 1

    duration_seconds = time.monotonic() - started_at
    try:
        atomic_write(
            options.status_file,
            render_collector_metrics(
                collection_succeeded, attempted_at, duration_seconds
            ),
        )
    except OSError as error:
        print(
            f"error: could not write collector status metrics: {error}", file=sys.stderr
        )
        exit_code = 1
    return exit_code


if __name__ == "__main__":
    raise SystemExit(run())
