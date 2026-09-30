"""Fixed production launchers and read-only aggregate monitoring; never repair state."""

from __future__ import annotations

import math
import os
import stat
import sys
import uuid
from collections.abc import Mapping
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from homelab_mcp.finance_signal.store import ReportSlot

DATABASE = Path("/var/lib/homelab-mcp/finances-context.db")
READER = "/run/finance-report-reader/reader.json"
KINDS = ("daily", "weekly")
# Match the report unit's stop grace, without extending the native send window.
REPORT_STOP_GRACE_SECONDS = 45
SIGNAL_FIELDS = ("NUMBER", "GROUP_ID", "OPS_GROUP_ID", "BOT_UUID", "CAPTURE_SENDERS")
METRICS = {
    "check_timestamp_seconds": "Local observer time, not delivery or bank freshness.",
    "path_healthy": "Canonical mounted context path has the required ownership and modes.",
    "listener_status_available": "Native read-only listener evidence was available.",
    "listener_healthy": "Current Family destination has a live connected fresh listener.",
    "ack_attention": "Native durable ACK evidence needs attention; never automatically retried.",
    "report_status_available": "Native current-slot status was read; zero before cutover.",
    "report_fulfilled": "Current scheduled purpose fulfilled, not device receipt.",
    "report_attention": "Current non-retryable failure or unknown/unverifiable outcome.",
    "report_deadline_timestamp_seconds": "Alarm deadline: native slot window plus stop grace; zero before cutover.",
    "report_next_slot_timestamp_seconds": "Next scheduled slot at or after cutover.",
}


class InvalidInput(ValueError):
    """Fixed safe diagnostic, never a value supplied by the environment."""


def diagnostic(code: str) -> None:
    print(f"finance_signal_{code}", file=sys.stderr)


def transport_environment(environ: Mapping[str, str], port: str) -> dict[str, str]:
    if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:
        raise InvalidInput("invalid_signal_port")
    result = {}
    for field in SIGNAL_FIELDS:
        key = f"HOMELAB_MCP_SIGNAL_{field}"
        value = environ.get(key, "")
        if (
            not value.strip()
            or len(value) > 16384
            or any(ord(c) < 32 or ord(c) == 127 for c in value)
        ):
            raise InvalidInput("invalid_signal_metadata")
        result[key] = value
    result["HOMELAB_MCP_SIGNAL_BASE_URL"] = f"http://127.0.0.1:{port}"
    return result


def environment(
    environ: Mapping[str, str], port: str, *, capture: bool
) -> dict[str, str]:
    result = transport_environment(environ, port)
    result["HOMELAB_MCP_FINANCES_CONTEXT_DB_PATH"] = str(DATABASE)
    if capture:
        result.update(
            HOMELAB_MCP_SIGNAL_CAPTURE_ENABLED="true",
            HOMELAB_MCP_SIGNAL_CAPTURE_MODE="production",
            HOMELAB_MCP_SIGNAL_CAPTURE_TIMEZONE="America/New_York",
            HOMELAB_MCP_SIGNAL_CAPTURE_DB_PATH=str(DATABASE),
        )
    else:
        result.update(
            HOMELAB_MCP_SIGNAL_REPORTS_ENABLED="true",
            HOMELAB_MCP_SIGNAL_REPORT_DB_PATH=str(DATABASE),
        )
        for key in ("PATH", "SSL_CERT_FILE", "GIT_SSL_CAINFO"):
            if key in environ:
                result[key] = environ[key]
    return result


def cutover(value: str) -> datetime:
    try:
        at = datetime.fromisoformat(value)
        if at.tzinfo is None or at.utcoffset() is None:
            raise ValueError
        return at
    except ValueError:
        raise InvalidInput("invalid_cutover_time") from None


def private_database(path: Path, *, mounted: bool = False) -> None:
    """Independent of native imports/status; check only, with no chmod/create/migration."""
    parent = path.parent.lstat()
    if (
        not stat.S_ISDIR(parent.st_mode)
        or parent.st_uid != os.geteuid()
        or stat.S_IMODE(parent.st_mode) != 0o700
        or (mounted and not os.path.ismount(path.parent))
    ):
        raise InvalidInput("unsafe_context_directory")
    for suffix in (
        "",
        "-journal",
        "-wal",
        "-shm",
        ".signal-listener.lock",
        ".signal-report.lock",
    ):
        file = Path(str(path) + suffix)
        try:
            info = file.lstat()
        except FileNotFoundError:
            if suffix:
                continue
            raise
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
        ):
            raise InvalidInput("unsafe_context_file")


def schedule(
    kind: str, at: datetime, not_before: datetime
) -> tuple[ReportSlot, float, float]:
    from homelab_mcp.finance_signal.store import (
        PRODUCTION_SLOT_WINDOW_SECONDS,
        report_slot,
    )

    slot = report_slot(kind, at)
    deadline = (
        (
            slot.scheduled_for + timedelta(seconds=PRODUCTION_SLOT_WINDOW_SECONDS)
        ).timestamp()
        if slot.scheduled_for >= not_before
        else 0
    )
    next_slot = report_slot(kind, max(at, not_before)).scheduled_for
    if next_slot <= at or next_slot < not_before:
        next_slot = report_slot(
            kind, next_slot + timedelta(days=1 if kind == "daily" else 7)
        ).scheduled_for
    return slot, deadline, next_slot.timestamp()


def due(kind: str, not_before: datetime) -> bool:
    at = datetime.now(UTC)
    _, deadline, _ = schedule(kind, at, not_before)
    return bool(deadline and at.timestamp() <= deadline)


def key(name: str, kind: str) -> str:
    return f'{name}{{kind="{kind}"}}'


def empty_metrics(at: datetime) -> dict[str, float]:
    values = {
        key(name, kind) if name.startswith("report_") else name: 0
        for name in METRICS
        for kind in (KINDS if name.startswith("report_") else ("",))
    }
    values["check_timestamp_seconds"] = at.timestamp()
    return values


def collect(
    path: Path,
    environ: Mapping[str, str],
    port: str,
    not_before: datetime,
    at: datetime,
) -> dict[str, float]:
    values = empty_metrics(at)
    try:
        private_database(path, mounted=True)
        values["path_healthy"] = 1
    except (OSError, InvalidInput):
        diagnostic("context_path_unhealthy")
    try:
        from homelab_mcp.finance_signal import report_job, status
        from homelab_mcp.finance_signal.protocol import SignalError
    except ImportError:
        diagnostic("native_status_import_failed")
        return values
    try:
        for kind in KINDS:
            _, deadline, next_slot = schedule(kind, at, not_before)
            values[key("report_deadline_timestamp_seconds", kind)] = (
                deadline + REPORT_STOP_GRACE_SECONDS if deadline else 0
            )
            values[key("report_next_slot_timestamp_seconds", kind)] = next_slot
        transport = report_job.load_config(
            environment(environ, port, capture=False)
        ).transport
        family = transport.destination("family").fingerprint
        ops = transport.destination("ops").fingerprint
    except (SignalError, InvalidInput, OSError):
        diagnostic("monitor_configuration_invalid")
        return values
    if not values["path_healthy"]:
        return values
    try:
        evidence = status.read_status(str(path), now=at.timestamp())
        if (
            type(evidence["schema_version"]) is not int
            or evidence["schema_version"] != 1
            or any(
                type(evidence[field]) is not bool
                for field in (
                    "receiver_healthy",
                    "delivery_attention",
                    "ok",
                    "heartbeat_fresh",
                )
            )
        ):
            raise InvalidInput("invalid_listener_status")
        if evidence["ok"] != (
            evidence["receiver_healthy"] and not evidence["delivery_attention"]
        ):
            raise InvalidInput("inconsistent_listener_status")
        listener = evidence["listener"]
        values["listener_status_available"] = 1
        values["listener_healthy"] = int(
            evidence["receiver_healthy"]
            and evidence["heartbeat_fresh"]
            and evidence["pid_alive"] is True
            and listener["state"] == "connected"
            and listener["mode"] == "production"
            and listener["target"] == "family"
            and listener["destination_fingerprint"] == family
        )
        values["ack_attention"] = int(evidence["delivery_attention"])
    except (SignalError, ValueError, KeyError, TypeError, OSError):
        diagnostic("listener_status_unavailable")
        values["listener_status_available"] = 0
        values["listener_healthy"] = 0
    for kind in KINDS:
        if not values[key("report_deadline_timestamp_seconds", kind)]:
            continue
        try:
            slot, _, _ = schedule(kind, at, not_before)
            evidence = report_job.read_report_status(
                str(path),
                kind=kind,
                expected_destination_fingerprint=family,
                expected_ops_destination_fingerprint=ops,
                at=at,
            )
            attempt = evidence["last_attempt"]
            current = attempt is not None and attempt["period"] == slot.period
            if (
                type(evidence["schema_version"]) is not int
                or evidence["schema_version"] != 1
                or evidence["mode"] != "production"
                or evidence["target"] != "family"
                or evidence["kind"] != kind
                or evidence["period"] != slot.period
                or datetime.fromisoformat(evidence["scheduled_for"])
                != slot.scheduled_for
                or datetime.fromisoformat(evidence["as_of"]) != at
                or type(evidence["ok"]) is not bool
                or type(evidence["destination_verified"]) is not bool
                or evidence["code"]
                not in report_job.REPORT_ATTEMPT_CODES | {"scheduled_report_missing"}
                or (
                    evidence["ok"]
                    and (
                        not current
                        or not evidence["destination_verified"]
                        or evidence["code"]
                        not in ("quiet_checked", "transport_accepted")
                    )
                )
            ):
                raise InvalidInput("invalid_report_status")
            values[key("report_status_available", kind)] = 1
            values[key("report_fulfilled", kind)] = int(evidence["ok"])
            values[key("report_attention", kind)] = int(
                current
                and not evidence["ok"]
                and evidence["code"]
                not in (
                    "preparing",
                    "prepared",
                    "scheduled_report_missing",
                    "preparation_failed",
                )
            )
        except (SignalError, ValueError, KeyError, TypeError, OSError):
            diagnostic(f"report_status_unavailable_{kind}")
            values[key("report_status_available", kind)] = 0
            values[key("report_fulfilled", kind)] = 0
            values[key("report_attention", kind)] = 1
    return values


def publish(path: Path, values: dict[str, float]) -> None:
    if values.keys() != empty_metrics(datetime.now(UTC)).keys() or any(
        type(value) not in (int, float) or not math.isfinite(value) or value < 0
        for value in values.values()
    ):
        raise InvalidInput("invalid_metrics")
    parent = path.parent.lstat()
    if (
        not stat.S_ISDIR(parent.st_mode)
        or parent.st_uid != os.geteuid()
        or stat.S_IMODE(parent.st_mode) != 0o2750
    ):
        raise InvalidInput("unsafe_metrics_directory")
    pending = path.with_name(f".{path.name}.{uuid.uuid4().hex}.pending")
    try:
        fd = os.open(
            pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o640
        )
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            os.fchmod(stream.fileno(), 0o640)
            for name, help_text in METRICS.items():
                metric = f"finance_signal_{name}"
                stream.write(f"# HELP {metric} {help_text}\n# TYPE {metric} gauge\n")
                for kind in KINDS if name.startswith("report_") else ("",):
                    sample = key(name, kind) if kind else name
                    stream.write(f"finance_signal_{sample} {values[sample]}\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(pending, path)
    finally:
        pending.unlink(missing_ok=True)


def main(argv: list[str]) -> int:
    os.umask(0o077)
    try:
        if len(argv) == 4 and argv[0] == "collect":
            values = collect(
                DATABASE, os.environ, argv[1], cutover(argv[2]), datetime.now(UTC)
            )
            publish(Path(argv[3]), values)
            return int(
                not values["path_healthy"] or not values["listener_status_available"]
            )
        if len(argv) == 3 and argv[0] == "due" and argv[1] in KINDS:
            if due(argv[1], cutover(argv[2])):
                return 0
            diagnostic("report_slot_not_due")
            return 1
        if len(argv) == 3 and argv[0] == "capture":
            private_database(DATABASE)
            os.execve(
                argv[1],
                [argv[1], "listen"],
                environment(os.environ, argv[2], capture=True),
            )
        if len(argv) == 5 and argv[0] == "report" and argv[2] in KINDS:
            if not due(argv[2], cutover(argv[4])):
                diagnostic("report_slot_not_due")
                return 1
            private_database(DATABASE)
            os.execve(
                argv[1],
                [
                    argv[1],
                    "run",
                    "--kind",
                    argv[2],
                    "--native-config",
                    READER,
                    "--send",
                ],
                environment(os.environ, argv[3], capture=False),
            )
        raise InvalidInput("invalid_arguments")
    except InvalidInput as exc:
        diagnostic(str(exc))
        return 255 if argv and argv[0] == "due" else 2
    except (OSError, ValueError, ImportError):
        diagnostic("runtime_failed")
        return 255 if argv and argv[0] == "due" else 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
