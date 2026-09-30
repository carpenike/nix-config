"""Offline production contracts against the pinned native APIs and synthetic state only."""

from __future__ import annotations

import asyncio
import base64
import contextlib
import importlib.util
import io
import os
import sqlite3
import stat
import sys
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import patch

from homelab_mcp.finance_signal import cli, report_job, status
from homelab_mcp.finance_signal.store import SignalStore, report_slot
from homelab_mcp.finances_context import ContextStore

MODULE = Path(
    os.environ.get(
        "FINANCE_SIGNAL_RUNTIME",
        Path(__file__).resolve().parents[2]
        / "hosts/forge/services/finance-signal-production/runtime.py",
    )
)
spec = importlib.util.spec_from_file_location("production_runtime", MODULE)
assert spec and spec.loader
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)

AT = datetime(2026, 10, 2, 20, 1, tzinfo=UTC)
BEFORE = datetime(2026, 10, 1, 4, tzinfo=UTC)


def group(byte: bytes) -> str:
    internal = base64.b64encode(byte * 32).decode()
    return "group." + base64.b64encode(internal.encode()).decode()


ENV = {
    "HOMELAB_MCP_SIGNAL_NUMBER": "+12025550123",
    "HOMELAB_MCP_SIGNAL_GROUP_ID": group(b"f"),
    "HOMELAB_MCP_SIGNAL_OPS_GROUP_ID": group(b"o"),
    "HOMELAB_MCP_SIGNAL_BOT_UUID": "11111111-1111-4111-8111-111111111111",
    "HOMELAB_MCP_SIGNAL_CAPTURE_SENDERS": "22222222-2222-4222-8222-222222222222",
}


def report(
    kind: str, at: datetime, *, ok: bool = True, code: str = "transport_accepted"
) -> dict:
    slot = report_slot(kind, at)
    return {
        "schema_version": 1,
        "mode": "production",
        "target": "family",
        "kind": kind,
        "period": slot.period,
        "scheduled_for": slot.scheduled_for.isoformat(),
        "as_of": at.isoformat(),
        "ok": ok,
        "code": code,
        "destination_verified": ok,
        "last_attempt": {"period": slot.period},
    }


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.private = self.root / "context"
        self.private.mkdir(mode=0o700)
        self.db = self.private / "finances-context.db"
        self.db.touch(mode=0o600)
        self.transport = report_job.load_config(
            runtime.environment(ENV, "18484", capture=False)
        ).transport
        self.store = SignalStore(str(self.db), production_db_path=str(self.db))
        self.addCleanup(self.store.close)
        self.heartbeat()
        # Every test, including real native reads, is forbidden from opening TCP.
        self.addCleanup(patch.stopall)
        patch(
            "socket.socket.connect", side_effect=AssertionError("network forbidden")
        ).start()
        patch("os.path.ismount", return_value=True).start()

    def heartbeat(self, *, at=AT, state="connected", destination=None):
        snapshot = status.ListenerSnapshot(
            run_id="1" * 32,
            pid=os.getpid(),
            mode="production",
            target="family",
            destination_fingerprint=destination
            or self.transport.destination("family").fingerprint,
            state=state,
            started_at=at.timestamp() - 60,
            heartbeat_at=at.timestamp(),
            last_connected_at=at.timestamp() - 60,
            last_disconnected_at=None,
            last_frame_at=None,
            last_error_code=None,
            last_error_at=None,
            queue_depth=0,
            counters=dict.fromkeys(status.COUNTERS, 0),
        )
        self.store.write_listener_snapshot(snapshot, starting=True)

    def collect(self, at=AT, before=BEFORE, reader=None):
        if reader is None:
            return runtime.collect(self.db, ENV, "18484", before, at)
        with patch.object(report_job, "read_report_status", side_effect=reader):
            return runtime.collect(self.db, ENV, "18484", before, at)

    def fresh(self, _database, *, kind, at, **_kwargs):
        return report(kind, at)

    def test_exact_native_capture_environment_no_ambient_credentials(self):
        poisoned = ENV | {
            "HOMELAB_MCP_SIGNAL_CAPTURE_MODE": "test",
            "HOMELAB_MCP_SIGNAL_CAPTURE_TEST_GROUP_ID": ENV[
                "HOMELAB_MCP_SIGNAL_OPS_GROUP_ID"
            ],
            "HOMELAB_MCP_SIGNAL_CAPTURE_DB_PATH": "/wrong.db",
            "HOMELAB_MCP_SIGNAL_BASE_URL": "https://wrong.invalid",
            "HOMELAB_MCP_FINANCES_CONTEXT_DB_PATH": "/other.db",
            "HOMELAB_MCP_FINANCES_SIDECAR_TOKEN": "never-forward",
            "HOMELAB_MCP_FINANCES_REPO_TOKEN": "never-forward",
            "HOMELAB_MCP_POCKETID_CLIENT_SECRET": "never-forward",
            "PYTHONPATH": "/untrusted",
            "BASH_ENV": "/untrusted",
            "PATH": "/untrusted",
        }
        selected = runtime.environment(poisoned, "18484", capture=True)
        self.assertNotIn("never-forward", selected.values())
        self.assertNotIn("PATH", selected)
        self.assertNotIn("HOMELAB_MCP_SIGNAL_CAPTURE_TEST_GROUP_ID", selected)
        config = cli.load_config(selected)
        self.assertEqual(config.mode, "production")
        self.assertEqual(config.database, str(runtime.DATABASE))
        self.assertEqual(config.transport.base_url, "http://127.0.0.1:18484")

    def test_exact_native_report_environment_and_launch(self):
        selected = runtime.environment(
            ENV | {"PATH": "/git", "LD_PRELOAD": "/bad"}, "8484", capture=False
        )
        config = report_job.load_config(selected)
        self.assertTrue(config.production_enabled)
        self.assertFalse(config.ops_preview)
        self.assertEqual(config.database, str(runtime.DATABASE))
        self.assertNotIn("LD_PRELOAD", selected)
        with (
            patch.object(runtime, "DATABASE", self.db),
            patch.dict(os.environ, ENV, clear=True),
            patch.object(runtime, "schedule", return_value=(None, float("inf"), 0)),
            patch("os.execve", side_effect=SystemExit(0)) as execute,
        ):
            with self.assertRaises(SystemExit):
                runtime.main(
                    ["report", "/native-report", "daily", "8484", BEFORE.isoformat()]
                )
        self.assertEqual(
            execute.call_args.args[1],
            [
                "/native-report",
                "run",
                "--kind",
                "daily",
                "--native-config",
                "/run/finance-report-reader/reader.json",
                "--send",
            ],
        )
        self.assertNotIn("--database", execute.call_args.args[1])
        self.assertNotIn("--ops-preview", execute.call_args.args[1])

    def test_capture_launch_only_native_listener(self):
        with (
            patch.object(runtime, "DATABASE", self.db),
            patch.dict(os.environ, ENV, clear=True),
            patch("os.execve", side_effect=SystemExit(0)) as execute,
        ):
            with self.assertRaises(SystemExit):
                runtime.main(["capture", "/native-listener", "8484"])
        self.assertEqual(execute.call_args.args[1], ["/native-listener", "listen"])

    def test_invalid_metadata_and_naive_cutover_rejected_without_values(self):
        for port in ("", "0", "65536", "\uff11\uff12", "http://private"):
            with self.subTest(port=port), self.assertRaises(runtime.InvalidInput):
                runtime.environment(ENV, port, capture=True)
        for value in (
            "",
            "2026-10-01T00:00:00",
            "private-value",
            "2026-99-01T00:00:00Z",
        ):
            with self.subTest(value=value), self.assertRaises(runtime.InvalidInput):
                runtime.cutover(value)
        with self.assertRaises(runtime.InvalidInput):
            runtime.environment(
                ENV | {"HOMELAB_MCP_SIGNAL_NUMBER": "private\nvalue"},
                "8484",
                capture=True,
            )

    def test_first_slots_and_fifteen_minute_deadline(self):
        at = datetime(2026, 9, 30, 12, 44, tzinfo=UTC)
        for kind, expected in (
            ("daily", datetime(2026, 10, 1, 12, tzinfo=UTC)),
            ("weekly", datetime(2026, 10, 2, 20, tzinfo=UTC)),
        ):
            _, deadline, next_slot = runtime.schedule(kind, at, BEFORE)
            self.assertEqual(deadline, 0)
            self.assertEqual(next_slot, expected.timestamp())
            slot, deadline, _ = runtime.schedule(kind, expected, BEFORE)
            self.assertEqual(deadline - slot.scheduled_for.timestamp(), 900)
            for minute in (0, 5, 10):
                self.assertEqual(
                    report_slot(kind, expected + timedelta(minutes=minute)), slot
                )

    def test_mid_slot_cutover_does_not_adopt_old_slot(self):
        at = datetime(2026, 10, 1, 12, 5, tzinfo=UTC)
        _, deadline, next_slot = runtime.schedule("daily", at, at)
        self.assertEqual(deadline, 0)
        self.assertEqual(next_slot, datetime(2026, 10, 2, 12, tzinfo=UTC).timestamp())

    def test_native_timezone_across_both_dst_changes(self):
        for at, expected in (
            (
                datetime(2026, 10, 31, 13, tzinfo=UTC),
                datetime(2026, 11, 1, 13, tzinfo=UTC),
            ),
            (
                datetime(2027, 3, 13, 14, tzinfo=UTC),
                datetime(2027, 3, 14, 12, tzinfo=UTC),
            ),
        ):
            self.assertEqual(
                runtime.schedule("daily", at, BEFORE)[2], expected.timestamp()
            )

    def test_due_gate_exact_deadline_and_no_catchup(self):
        start = datetime(2026, 10, 1, 12, tzinfo=UTC)
        for seconds, expected in (
            (-1, False),
            (0, True),
            (300, True),
            (600, True),
            (899, True),
            (900, True),
            (901, False),
        ):
            with (
                self.subTest(seconds=seconds),
                patch.object(runtime, "datetime", wraps=datetime) as clock,
            ):
                clock.now.return_value = start + timedelta(seconds=seconds)
                self.assertEqual(runtime.due("daily", BEFORE), expected)

    def test_due_configuration_errors_fail_the_systemd_condition(self):
        for arguments in (
            ["due", "daily", "2026-13-01T00:00:00-04:00"],
            ["due", "daily", "2026-10-01"],
            ["due", "untrusted-kind", "2026-10-01T00:00:00-04:00"],
        ):
            with self.subTest(arguments=arguments):
                self.assertEqual(runtime.main(arguments), 255)

    def test_pre_cutover_missing_or_failed_reports_do_not_page(self):
        at = datetime(2026, 9, 30, 12, 44, tzinfo=UTC)
        self.heartbeat(at=at)
        with patch.object(
            report_job, "read_report_status", side_effect=AssertionError("not yet owed")
        ):
            values = self.collect(at=at)
        self.assertEqual(values["listener_healthy"], 1)
        for kind in runtime.KINDS:
            self.assertEqual(
                values[runtime.key("report_deadline_timestamp_seconds", kind)], 0
            )
            self.assertEqual(values[runtime.key("report_attention", kind)], 0)

    def test_current_native_missing_status_is_read_only_not_success(self):
        before = self.db.read_bytes()
        values = self.collect()
        self.assertEqual(self.db.read_bytes(), before)
        self.assertEqual(values["listener_healthy"], 1)
        for kind in runtime.KINDS:
            self.assertEqual(values[runtime.key("report_status_available", kind)], 1)
            self.assertEqual(values[runtime.key("report_fulfilled", kind)], 0)

    def test_old_native_failure_cannot_fulfill_current_slot(self):
        at = AT - timedelta(days=1)
        attempt = self.store.begin_report_attempt(
            report_slot("daily", at),
            self.transport.destination("family"),
            at=at,
            ops_destination=self.transport.destination("ops"),
        )
        self.store.finish_report_attempt(attempt, code="report_job_failed", at=at)
        values = self.collect()
        self.assertEqual(values[runtime.key("report_fulfilled", "daily")], 0)
        self.assertEqual(values[runtime.key("report_attention", "daily")], 0)
        self.assertLess(
            values[runtime.key("report_deadline_timestamp_seconds", "daily")],
            AT.timestamp(),
        )

    def test_fresh_and_quiet_native_status_contracts(self):
        for code in ("transport_accepted", "quiet_checked"):

            def read(_database, *, kind, at, **_kwargs):
                return report(kind, at, code=code)

            values = self.collect(reader=read)
            for kind in runtime.KINDS:
                self.assertEqual(values[runtime.key("report_fulfilled", kind)], 1)
                self.assertEqual(values[runtime.key("report_attention", kind)], 0)

    def test_current_unknown_failed_reserved_and_rotation_are_red(self):
        for code in (
            "ops_outbox_unknown",
            "outbox_failed",
            "outbox_reserved",
            "ops_destination_changed",
        ):
            with self.subTest(code=code):

                def read(_database, *, kind, at, **_kwargs):
                    return report(kind, at, ok=False, code=code)

                values = self.collect(reader=read)
                self.assertEqual(values[runtime.key("report_fulfilled", "weekly")], 0)
                self.assertEqual(values[runtime.key("report_attention", "weekly")], 1)

    def test_failed_preparation_then_recovery_keeps_one_slot_and_alarm_deadline(self):
        slot = report_slot("weekly", AT)
        first_at = slot.scheduled_for + timedelta(minutes=4)
        self.heartbeat(at=first_at)

        def failed_preparation(_database, *, kind, at, **_kwargs):
            return report(
                kind,
                at,
                ok=kind != "weekly",
                code="preparation_failed" if kind == "weekly" else "transport_accepted",
            )

        first = self.collect(at=first_at, reader=failed_preparation)
        self.assertEqual(first[runtime.key("report_status_available", "weekly")], 1)
        self.assertEqual(first[runtime.key("report_fulfilled", "weekly")], 0)
        self.assertEqual(first[runtime.key("report_attention", "weekly")], 0)
        deadline = first[runtime.key("report_deadline_timestamp_seconds", "weekly")]
        self.assertEqual(deadline, slot.scheduled_for.timestamp() + 900 + 45)

        second_at = slot.scheduled_for + timedelta(minutes=6)
        self.heartbeat(at=second_at)
        second = self.collect(at=second_at, reader=self.fresh)
        self.assertEqual(second[runtime.key("report_fulfilled", "weekly")], 1)
        self.assertEqual(second[runtime.key("report_attention", "weekly")], 0)
        self.assertEqual(
            second[runtime.key("report_deadline_timestamp_seconds", "weekly")], deadline
        )

    def test_current_destination_fingerprints_come_from_transport_not_state(self):
        calls = []

        def read(database, **kwargs):
            calls.append(kwargs)
            return self.fresh(database, **kwargs)

        self.collect(reader=read)
        for call in calls:
            self.assertEqual(
                call["expected_destination_fingerprint"],
                self.transport.destination("family").fingerprint,
            )
            self.assertEqual(
                call["expected_ops_destination_fingerprint"],
                self.transport.destination("ops").fingerprint,
            )

    def test_malformed_stale_or_false_green_status_fails_closed(self):
        for replacement in (
            {"schema_version": True},
            {"ok": "true"},
            {"scheduled_for": (AT - timedelta(days=1)).isoformat()},
            {"as_of": (AT - timedelta(seconds=1)).isoformat()},
            {"destination_verified": False},
            {"code": "unknown_success"},
            {"last_attempt": {"period": "old-period"}},
        ):
            with self.subTest(replacement=replacement):

                def read(_database, *, kind, at, **_kwargs):
                    return report(kind, at) | replacement

                with contextlib.redirect_stderr(io.StringIO()):
                    values = self.collect(reader=read)
                self.assertEqual(values[runtime.key("report_fulfilled", "weekly")], 0)
                self.assertEqual(
                    values[runtime.key("report_status_available", "weekly")], 0
                )

    def test_listener_disconnect_stale_and_wrong_destination_are_red(self):
        for state, age, destination in (
            ("backoff", 0, None),
            ("failed", 0, None),
            ("connected", 91, None),
            ("connected", 0, "0" * 64),
        ):
            with self.subTest(state=state, age=age, destination=destination):
                self.heartbeat(
                    at=AT - timedelta(seconds=age), state=state, destination=destination
                )
                self.assertEqual(self.collect()["listener_healthy"], 0)

    def test_failed_ack_remains_visible_with_fresh_listener(self):
        evidence = status.read_status(str(self.db), now=AT.timestamp())
        evidence.update(delivery_attention=True, ok=False)
        with patch.object(status, "read_status", return_value=evidence):
            values = self.collect()
        self.assertEqual(values["listener_healthy"], 1)
        self.assertEqual(values["ack_attention"], 1)

    def test_path_health_independent_of_broken_native_listener(self):
        with (
            patch.object(status, "read_status", side_effect=OSError("private-details")),
            contextlib.redirect_stderr(io.StringIO()) as log,
        ):
            values = self.collect(reader=self.fresh)
        self.assertEqual(values["path_healthy"], 1)
        self.assertEqual(values["check_timestamp_seconds"], AT.timestamp())
        self.assertEqual(values["listener_healthy"], 0)
        self.assertEqual(values[runtime.key("report_fulfilled", "weekly")], 1)
        self.assertNotIn("private-details", log.getvalue())

    def test_0644_missing_mount_and_unsafe_sidefiles_fail_without_repair(self):
        original = self.db.read_bytes()
        self.db.chmod(0o644)
        with self.assertRaises(runtime.InvalidInput):
            runtime.private_database(self.db)
        self.assertEqual(stat.S_IMODE(self.db.stat().st_mode), 0o644)
        self.assertEqual(self.db.read_bytes(), original)
        self.db.chmod(0o600)
        with (
            patch("os.path.ismount", return_value=False),
            self.assertRaises(runtime.InvalidInput),
        ):
            runtime.private_database(self.db, mounted=True)
        for suffix in (
            "-wal",
            "-shm",
            "-journal",
            ".signal-report.lock",
            ".signal-listener.lock",
        ):
            file = Path(str(self.db) + suffix)
            file.touch(mode=0o644)
            file.chmod(0o644)
            with self.subTest(suffix=suffix), self.assertRaises(runtime.InvalidInput):
                runtime.private_database(self.db)
            file.unlink()
        with self.assertRaises(FileNotFoundError):
            runtime.private_database(self.private / "absent.db")
        self.assertFalse((self.private / "absent.db").exists())

    def test_symlink_hardlink_wrong_owner_and_parent_mode_rejected(self):
        link = self.private / "link.db"
        link.symlink_to(self.db)
        with self.assertRaises(runtime.InvalidInput):
            runtime.private_database(link)
        link.unlink()
        os.link(self.db, link)
        with self.assertRaises(runtime.InvalidInput):
            runtime.private_database(self.db)
        link.unlink()
        with (
            patch("os.geteuid", return_value=os.geteuid() + 1),
            self.assertRaises(runtime.InvalidInput),
        ):
            runtime.private_database(self.db)
        self.private.chmod(0o750)
        with self.assertRaises(runtime.InvalidInput):
            runtime.private_database(self.db)

    def test_atomic_fixed_metrics_and_reader_permissions(self):
        directory = self.root / "metrics"
        directory.mkdir()
        os.chown(directory, -1, os.getegid())
        directory.chmod(0o2750)
        if sys.platform == "darwin" and not directory.stat().st_mode & stat.S_ISGID:
            self.skipTest(
                "Darwin Nix sandbox strips setgid; also run outside the sandbox"
            )
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o2750)
        self.assertEqual(directory.stat().st_uid, os.geteuid())
        path = directory / "finance_signal.prom"
        values = self.collect(reader=self.fresh)
        runtime.publish(path, values)
        before = path.read_bytes()
        inode = path.stat().st_ino
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
        self.assertEqual(path.stat().st_gid, directory.stat().st_gid)
        text = before.decode()
        self.assertEqual(text.count("# TYPE "), 10)
        self.assertEqual(text.count("{kind="), 10)
        for private in (
            *ENV.values(),
            str(self.db),
            "destination_fingerprint",
            "run_id",
        ):
            self.assertNotIn(private, text)
        with (
            patch("os.replace", side_effect=OSError("synthetic failure")),
            self.assertRaises(OSError),
        ):
            runtime.publish(path, values)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(directory.iterdir()), [path])
        runtime.publish(path, values)
        self.assertNotEqual(inode, path.stat().st_ino)
        with self.assertRaises(runtime.InvalidInput):
            runtime.publish(path, values | {"private_note": 1})
        with self.assertRaises(runtime.InvalidInput):
            runtime.publish(path, values | {"path_healthy": float("nan")})

    def test_metrics_do_not_repair_or_create_directory(self):
        directory = self.root / "metrics"
        directory.mkdir(mode=0o777)
        with self.assertRaises(runtime.InvalidInput):
            runtime.publish(
                directory / "finance_signal.prom", runtime.empty_metrics(AT)
            )
        self.assertEqual(list(directory.iterdir()), [])

    def test_read_only_monitor_keeps_context_rows_and_mode(self):
        async def seed():
            context = ContextStore(str(self.db))
            try:
                for index in range(9):
                    await context.add(
                        author=f"fixture-{index % 2}",
                        note=f"Unchanged synthetic note {index}\nverbatim second line",
                        source="synthetic-signal",
                        ref_date=None,
                        ref_amount=None,
                        ref_payee=None,
                        created_at=(AT - timedelta(days=180)).timestamp(),
                    )
                await context.consume([1, 3], by="fixture-reviewer", note=None)
            finally:
                context._conn.close()

        asyncio.run(seed())
        with contextlib.closing(sqlite3.connect(self.db)) as connection:
            before = connection.execute(
                "SELECT * FROM txn_context ORDER BY id"
            ).fetchall()
            self.assertEqual(len(before), 9)
            self.assertEqual(
                dict(
                    connection.execute(
                        "SELECT status, COUNT(*) FROM txn_context GROUP BY status"
                    )
                ),
                {"consumed": 2, "open": 7},
            )
        bytes_before = self.db.read_bytes()
        self.collect()
        with contextlib.closing(sqlite3.connect(self.db)) as connection:
            after = connection.execute(
                "SELECT * FROM txn_context ORDER BY id"
            ).fetchall()
        self.assertEqual(after, before)
        self.assertEqual(bytes_before, self.db.read_bytes())
        self.assertEqual(stat.S_IMODE(self.db.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
