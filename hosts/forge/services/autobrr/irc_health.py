#!/usr/bin/env python3
"""Export autobrr IRC network health for Prometheus.

autobrr 1.89.0's /metrics endpoint does not publish per-network or per-channel
health gauges. This reads GET /api/irc (the same object the UI uses) and writes
node_exporter textfile gauges labeled with the network and channel. Disabled
networks and disabled channels are omitted so intentionally stopped indexers
do not alert.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections.abc import Mapping, Sequence
from typing import Any

MAX_RESPONSE_BYTES = 1_000_000
MAX_TOKEN_LENGTH = 512

MetricSample = tuple[str, dict[str, str], int]


class SchemaError(ValueError):
    """The API JSON was not the IRC health list this exporter understands."""


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError(f"autobrr API returned HTTP {code}")


def _escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _format_value(value: bool | int) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    return str(value)


def metric_line(
    metric_name: str,
    value: bool | int,
    labels: Mapping[str, str] | None = None,
) -> str:
    label_text = ""
    if labels:
        rendered = ",".join(
            f'{label_name}="{_escape_label(label_value)}"'
            for label_name, label_value in sorted(labels.items())
        )
        label_text = f"{{{rendered}}}"
    return f"{metric_name}{label_text} {_format_value(value)}"


def _metric_header(metric_name: str, help_text: str) -> list[str]:
    return [
        f"# HELP {metric_name} {help_text}",
        f"# TYPE {metric_name} gauge",
    ]


def _require_bool(obj: Mapping[str, Any], key: str) -> bool:
    value = obj.get(key)
    if not isinstance(value, bool):
        raise SchemaError(f"{key} was not a boolean")
    return value


def _require_name(value: Any, kind: str) -> str:
    if not isinstance(value, str) or value == "":
        raise SchemaError(f"{kind} name was missing")
    if "\n" in value or "\r" in value:
        raise SchemaError(f"{kind} name contained a newline")
    return value


def samples_from_networks(networks: Any) -> list[MetricSample]:
    """Enabled networks and their enabled channels only."""
    if not isinstance(networks, list):
        raise SchemaError("IRC payload was not a list")

    samples: list[MetricSample] = []
    for network in networks:
        if not isinstance(network, dict):
            raise SchemaError("network entry was not an object")
        enabled = _require_bool(network, "enabled")
        name = _require_name(network.get("name"), "network")
        if not enabled:
            continue

        network_labels = {"network": name}
        samples.append(
            (
                "autobrr_irc_network_connected",
                network_labels,
                1 if _require_bool(network, "connected") else 0,
            )
        )
        samples.append(
            (
                "autobrr_irc_network_healthy",
                network_labels,
                1 if _require_bool(network, "healthy") else 0,
            )
        )

        channels = network.get("channels")
        if not isinstance(channels, list):
            raise SchemaError("channels was not a list")
        for channel in channels:
            if not isinstance(channel, dict):
                raise SchemaError("channel entry was not an object")
            if not _require_bool(channel, "enabled"):
                continue
            channel_name = _require_name(channel.get("name"), "channel")
            samples.append(
                (
                    "autobrr_irc_channel_monitoring",
                    {"network": name, "channel": channel_name},
                    1 if _require_bool(channel, "monitoring") else 0,
                )
            )
    return _dedupe_unhealthy(samples)


def _dedupe_unhealthy(samples: list[MetricSample]) -> list[MetricSample]:
    """One series per label set. If two rows disagree, keep the unhealthy 0."""
    merged: dict[tuple[str, tuple[tuple[str, str], ...]], int] = {}
    order: list[tuple[str, tuple[tuple[str, str], ...]]] = []
    for metric_name, labels, value in samples:
        key = (metric_name, tuple(sorted(labels.items())))
        if key not in merged:
            order.append(key)
            merged[key] = value
        else:
            merged[key] = min(merged[key], value)
    return [
        (metric_name, dict(labels), merged[(metric_name, labels)])
        for metric_name, labels in order
    ]


HEALTH_METRICS = (
    (
        "autobrr_irc_network_connected",
        "1 if an enabled autobrr IRC network has a live connection",
    ),
    (
        "autobrr_irc_network_healthy",
        "1 if autobrr reports an enabled IRC network healthy",
    ),
    (
        "autobrr_irc_channel_monitoring",
        "1 if an enabled IRC channel is joined and monitoring",
    ),
)


def render(*, success: bool, timestamp: int, networks: Any) -> str:
    if timestamp < 0:
        raise ValueError("timestamp must be >= 0")
    grouped: dict[str, list[str]] = {name: [] for name, _help in HEALTH_METRICS}
    if success:
        parsed = samples_from_networks(networks)
        parsed.sort(
            key=lambda sample: (
                sample[0],
                sample[1].get("network", ""),
                sample[1].get("channel", ""),
            )
        )
        for metric_name, labels, value in parsed:
            grouped[metric_name].append(metric_line(metric_name, value, labels))

    lines: list[str] = []
    for metric_name, help_text in HEALTH_METRICS:
        lines.extend(_metric_header(metric_name, help_text))
        lines.extend(grouped[metric_name])
    lines.extend(
        _metric_header(
            "autobrr_irc_health_scrape_success",
            "1 if the latest autobrr IRC API read succeeded",
        )
    )
    lines.append(metric_line("autobrr_irc_health_scrape_success", success))
    lines.extend(
        _metric_header(
            "autobrr_irc_health_last_scrape_timestamp_seconds",
            "Unix time of the latest autobrr IRC API read attempt",
        )
    )
    lines.append(
        metric_line("autobrr_irc_health_last_scrape_timestamp_seconds", timestamp)
    )
    return "\n".join(lines) + "\n"


def fetch_networks(url: str, token: str, timeout: float) -> list[Any]:
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        _RejectRedirects(),
    )
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": "autobrr-irc-health/1",
            "X-API-Token": token,
        },
        method="GET",
    )
    try:
        with opener.open(request, timeout=timeout) as response:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"autobrr API returned HTTP {exc.code}") from None
    except urllib.error.URLError:
        raise RuntimeError("autobrr API request failed") from None
    if len(payload) > MAX_RESPONSE_BYTES:
        raise RuntimeError("autobrr API response exceeded 1 MB")
    try:
        document = json.loads(payload)
    except json.JSONDecodeError:
        raise RuntimeError("autobrr API returned invalid JSON") from None
    if not isinstance(document, list):
        raise SchemaError("IRC payload was not a list")
    return document


def atomic_write(path: pathlib.Path, content: str) -> None:
    temporary_path: pathlib.Path | None = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
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
        os.chmod(temporary_path, 0o644)
        os.replace(temporary_path, path)
        temporary_path = None
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def parse_arguments(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--token-file", type=pathlib.Path, required=True)
    parser.add_argument("--metrics-file", type=pathlib.Path, required=True)
    parser.add_argument("--timeout", type=float, default=15.0)
    return parser.parse_args(arguments)


def _read_token(path: pathlib.Path) -> str:
    try:
        token = path.read_text(encoding="utf-8").strip()
    except OSError:
        raise RuntimeError("could not read the autobrr API token file") from None
    if token == "":
        raise RuntimeError("autobrr API token file is empty")
    if len(token) > MAX_TOKEN_LENGTH:
        raise RuntimeError("autobrr API token file is unexpectedly long")
    return token


def main(arguments: Sequence[str] | None = None) -> int:
    options = parse_arguments(arguments)
    timestamp = int(time.time())
    try:
        token = _read_token(options.token_file)
        networks = fetch_networks(options.url, token, options.timeout)
        body = render(success=True, timestamp=timestamp, networks=networks)
    except (RuntimeError, SchemaError, ValueError) as exc:
        print(f"autobrr IRC health scrape failed: {exc}", file=sys.stderr)
        body = render(success=False, timestamp=timestamp, networks=[])
    atomic_write(options.metrics_file, body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
