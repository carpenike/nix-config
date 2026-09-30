"""Publish only aggregate export evidence; private CLI output never reaches logs."""

import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time


METRICS = {
    "status_available": "Whether the exporter status could be verified.",
    "export_failed": "Whether the last recorded export failed or this check was invalid.",
    "check_timestamp_seconds": "Observer time of this check, NOT snapshot freshness.",
    "last_success_timestamp_seconds": "Last successful export time, or zero if unknown.",
    "checkpoint_ingestion_finished_timestamp_seconds": "Published ingestion completion time, or zero.",
    "checkpoint_export_finished_timestamp_seconds": "Checkpoint export completion time, or zero.",
}


def timestamp(value, now):
    if (
        type(value) not in (int, float)
        or not math.isfinite(value)
        or value < 0
        or value > now
    ):
        raise ValueError("Invalid timestamp")
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def invalid_constant(_value):
    raise ValueError("Non-JSON numeric constant")


def evidence(raw, returncode, started, now):
    if len(raw) > 1024 * 1024:
        raise ValueError("Oversized status")
    status = json.loads(
        raw, object_pairs_hook=unique_object, parse_constant=invalid_constant
    )
    if not isinstance(status, dict):
        raise ValueError("Invalid status")
    if type(status["schema_version"]) is not int or status["schema_version"] != 1:
        raise ValueError("Unsupported schema")
    if status["action"] not in ("published", "already_current", "waiting", "failed"):
        raise ValueError("Invalid action")
    if (
        type(status["exit_code"]) is not int
        or status["exit_code"] not in (0, 1, 2)
        or returncode != status["exit_code"]
    ):
        raise ValueError("Invalid exit status")
    if timestamp(status["observed_at"], now) < started:
        raise ValueError("Stale observation")
    for key in ("status_available", "export_failed"):
        if type(status[key]) is not bool:
            raise ValueError("Invalid flag")
    if (
        status["action"] == "failed"
        or returncode != 0
        or not status["status_available"]
    ) and not status["export_failed"]:
        raise ValueError("Failure without evidence")
    attempt = status["last_attempt"]
    if attempt is not None:
        if not isinstance(attempt, dict) or type(attempt.get("ok")) is not bool:
            raise ValueError("Invalid attempt")
        attempt_start = timestamp(attempt["started_at"], now)
        attempt_finish = timestamp(attempt["finished_at"], now)
        if not 0 < attempt_start <= attempt_finish:
            raise ValueError("Invalid attempt ordering")
        if not attempt["ok"] and not status["export_failed"]:
            raise ValueError("Recorded failure hidden by aggregate status")
    success = status["last_success_at"]
    if success is not None:
        timestamp(success, now)
    checkpoint = status["checkpoint"]
    if checkpoint is not None:
        if not isinstance(checkpoint, dict):
            raise ValueError("Invalid checkpoint")
        if not isinstance(checkpoint["ingestion_run_id"], str) or not re.fullmatch(
            r"[0-9a-f]{32}", checkpoint["ingestion_run_id"]
        ):
            raise ValueError("Invalid checkpoint identity")
        if checkpoint["ingestion_status"] not in ("succeeded", "degraded"):
            raise ValueError("Invalid checkpoint outcome")
        start = timestamp(checkpoint["ingestion_started_at"], now)
        finish = timestamp(checkpoint["ingestion_finished_at"], now)
        exported = timestamp(checkpoint["export_finished_at"], now)
        if not 0 < start <= finish <= exported or success is None or success < exported:
            raise ValueError("Invalid checkpoint ordering")
        if "degraded" in checkpoint and not isinstance(checkpoint["degraded"], list):
            raise ValueError("Invalid checkpoint degradation")
    elif status["action"] in ("published", "already_current"):
        raise ValueError("Missing checkpoint")
    values = {
        "status_available": int(status["status_available"]),
        # A no-op is NOT recovery. Only the CLI's durable export evidence counts.
        "export_failed": int(status["export_failed"]),
        "check_timestamp_seconds": now,
        "last_success_timestamp_seconds": success if success is not None else 0,
        "checkpoint_ingestion_finished_timestamp_seconds": (
            checkpoint["ingestion_finished_at"] if checkpoint is not None else 0
        ),
        "checkpoint_export_finished_timestamp_seconds": (
            checkpoint["export_finished_at"] if checkpoint is not None else 0
        ),
    }
    return values, status["action"]


def publish(path, values):
    pending = path.with_name(f".{path.name}.{os.getpid()}.pending")
    try:
        fd = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o640)
        with os.fdopen(fd, "w", encoding="ascii") as output:
            os.fchmod(output.fileno(), 0o640)
            for key, help_text in METRICS.items():
                name = f"finance_snapshot_{key}"
                output.write(f"# HELP {name} {help_text}\n# TYPE {name} gauge\n")
                output.write(f"{name} {values[key]}\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(pending, path)
    finally:
        pending.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exporter", required=True)
    parser.add_argument("--ingestion-state", required=True)
    parser.add_argument("--metrics-file", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=210)
    args = parser.parse_args()
    started = time.time()
    try:
        result = subprocess.run(
            [
                args.exporter,
                "--after-ingestion",
                "--json",
                "--ingestion-state",
                args.ingestion_state,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=args.timeout,
            check=False,
        )
        values, action = evidence(
            result.stdout, result.returncode, started, time.time()
        )
        if values["export_failed"]:
            print(
                f"Finance snapshot failure remains unresolved: action={action}, "
                f"exit={result.returncode}, status_available={values['status_available']}.",
                file=sys.stderr,
            )
        elif action == "published":
            print(
                "Finance snapshot checkpoint published; bank freshness is reported separately.",
                file=sys.stderr,
            )
    except (
        OSError,
        subprocess.SubprocessError,
        ValueError,
        KeyError,
        TypeError,
        OverflowError,
    ):
        # No exception text, stdout, stderr, account identity, or degradation
        # message is safe to log. Unavailable evidence must never look healthy.
        values = dict.fromkeys(METRICS, 0)
        values.update(
            status_available=0, export_failed=1, check_timestamp_seconds=time.time()
        )
        print(
            "Finance snapshot check unavailable; inspect the private exporter status.",
            file=sys.stderr,
        )
    try:
        publish(args.metrics_file, values)
    except OSError:
        print(
            "Finance snapshot metrics publication failed; prior evidence retained.",
            file=sys.stderr,
        )
        return 1
    return int(not values["status_available"] or values["export_failed"])


if __name__ == "__main__":
    sys.exit(main())
