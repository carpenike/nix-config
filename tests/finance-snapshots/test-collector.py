"""Offline wrapper fixtures. All fixtures live below the invocation directory."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import time
import unittest


COLLECTOR = Path(os.environ["SNAPSHOT_COLLECTOR"]).resolve()
spec = importlib.util.spec_from_file_location("collector", COLLECTOR)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)
PRIVATE = "private-account-name/opaque-run-id/private-degradation/secret-dsn"


def report():
    return {
        "schema_version": 1,
        "action": "published",
        "exit_code": 0,
        "observed_at": 0,  # Filled by the child at observation time.
        "status_available": True,
        "export_failed": False,
        "last_attempt": {"started_at": 300, "finished_at": 400, "ok": True},
        "last_success_at": 400,
        "checkpoint": {
            "ingestion_run_id": "0" * 32,
            "ingestion_started_at": 100,
            "ingestion_finished_at": 200,
            "ingestion_status": "degraded",
            "export_finished_at": 400,
            "degraded": [PRIVATE],
        },
    }


class CollectorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path("snapshot-fixtures").resolve()
        cls.root.mkdir()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root)

    def setUp(self):
        self.path = self.root / self._testMethodName
        self.path.mkdir()
        self.output = self.path / "snapshot.prom"
        self.input = self.path / "status.json"
        self.cli = self.path / "exporter"
        self.cli.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys, time\n"
            "from pathlib import Path\n"
            "assert sys.argv[1:] == ['--after-ingestion', '--json', '--ingestion-state', 'readonly-state.json']\n"
            "print(os.environ['PRIVATE_FIXTURE'], file=sys.stderr)\n"
            "time.sleep(float(os.environ.get('FIXTURE_SLEEP', 0)))\n"
            "data = Path(os.environ['FIXTURE_INPUT']).read_text()\n"
            "if os.environ.get('FIXTURE_RAW') != '1':\n"
            "    body = json.loads(data)\n"
            "    body['observed_at'] = time.time() + float(os.environ.get('FIXTURE_CLOCK_OFFSET', 0))\n"
            "    data = json.dumps(body)\n"
            "print(data)\n"
            "sys.exit(int(os.environ.get('FIXTURE_EXIT', 0)))\n"
        )
        self.cli.chmod(0o700)
        self.input.write_text(json.dumps(report()))

    def run_collector(self, **env):
        result = subprocess.run(
            [
                sys.executable,
                str(COLLECTOR),
                "--exporter",
                str(self.cli),
                "--ingestion-state",
                "readonly-state.json",
                "--metrics-file",
                str(self.output),
                "--timeout",
                "1",
            ],
            env=os.environ
            | {
                "FIXTURE_INPUT": str(self.input),
                "PRIVATE_FIXTURE": PRIVATE,
            }
            | env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertNotIn(PRIVATE, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse(list(self.path.glob("*.pending")))
        return result

    def metrics(self):
        text = self.output.read_text()
        self.assertNotIn(PRIVATE, text)
        self.assertNotIn("{", text)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o640)
        if shutil.which("promtool"):
            subprocess.run(
                ["promtool", "check", "metrics"],
                input=text,
                text=True,
                capture_output=True,
                check=True,
            )
        values = {
            key.removeprefix("finance_snapshot_"): float(value)
            for key, value in (
                line.split() for line in text.splitlines() if not line.startswith("#")
            )
        }
        self.assertEqual(set(values), set(collector.METRICS))
        return values

    def test_publish_aggregate_only_and_node_readable(self):
        os.chmod(self.path, 0o2750)
        before = time.time()
        self.assertEqual(self.run_collector().returncode, 0)
        values = self.metrics()
        self.assertEqual(values["status_available"], 1)
        self.assertEqual(values["export_failed"], 0)
        self.assertGreaterEqual(values["check_timestamp_seconds"], before)
        self.assertEqual(values["last_success_timestamp_seconds"], 400)
        self.assertEqual(values["checkpoint_ingestion_finished_timestamp_seconds"], 200)
        self.assertEqual(self.output.stat().st_gid, self.path.stat().st_gid)

    def test_waiting_and_already_current_preserve_durable_evidence(self):
        for action in ("waiting", "already_current"):
            for failed in (False, True):
                with self.subTest(action=action, failed=failed):
                    body = report() | {"action": action, "export_failed": failed}
                    self.input.write_text(json.dumps(body))
                    self.assertEqual(self.run_collector().returncode, int(failed))
                    values = self.metrics()
                    self.assertEqual(values["export_failed"], int(failed))
                    self.assertEqual(
                        values["checkpoint_export_finished_timestamp_seconds"], 400
                    )
                    self.assertEqual(values["last_success_timestamp_seconds"], 400)

    def test_waiting_without_a_checkpoint_is_not_a_failure(self):
        self.input.write_text(
            json.dumps(
                report()
                | {
                    "action": "waiting",
                    "last_attempt": None,
                    "last_success_at": None,
                    "checkpoint": None,
                }
            )
        )
        self.assertEqual(self.run_collector().returncode, 0)
        self.assertEqual(self.metrics()["export_failed"], 0)
        self.assertEqual(
            self.metrics()["checkpoint_ingestion_finished_timestamp_seconds"], 0
        )

    def test_nonzero_cli_failure_evidence_is_published(self):
        for code in (1, 2):
            with self.subTest(code=code):
                self.input.write_text(
                    json.dumps(
                        report()
                        | {
                            "action": "failed",
                            "exit_code": code,
                            "export_failed": True,
                        }
                    )
                )
                self.assertEqual(
                    self.run_collector(FIXTURE_EXIT=str(code)).returncode, 1
                )
                values = self.metrics()
                self.assertEqual(values["status_available"], 1)
                self.assertEqual(values["export_failed"], 1)
                self.assertEqual(values["last_success_timestamp_seconds"], 400)

    def test_contradictory_nonzero_success_is_not_accepted(self):
        self.input.write_text(json.dumps(report() | {"exit_code": 1}))
        self.assertEqual(self.run_collector(FIXTURE_EXIT="1").returncode, 1)
        self.assertEqual(self.metrics()["status_available"], 0)
        self.assertEqual(self.metrics()["export_failed"], 1)

    def test_invalid_json_contract_never_publishes_healthy_evidence(self):
        malformed = [
            "",
            PRIVATE,
            "null",
            "[]",
            json.dumps(report() | {"schema_version": True}),
            json.dumps(report() | {"schema_version": 2}),
            json.dumps(report() | {"status_available": "true"}),
            json.dumps(report() | {"last_attempt": []}),
            json.dumps(
                report()
                | {
                    "last_attempt": {
                        "started_at": 300,
                        "finished_at": 400,
                        "ok": False,
                    },
                }
            ),
            json.dumps(
                report()
                | {
                    "last_attempt": {"started_at": 400, "finished_at": 300, "ok": True},
                }
            ),
            json.dumps(
                report()
                | {
                    "checkpoint": report()["checkpoint"]
                    | {"ingestion_run_id": PRIVATE},
                }
            ),
            json.dumps(
                report()
                | {
                    "checkpoint": report()["checkpoint"]
                    | {"ingestion_status": "failed"},
                }
            ),
            json.dumps(
                report()
                | {
                    "checkpoint": report()["checkpoint"] | {"ingestion_started_at": 0},
                }
            ),
            json.dumps(report() | {"last_success_at": None}),
            json.dumps(report() | {"last_success_at": 399}),
            json.dumps(report() | {"checkpoint": None}),
            json.dumps(report() | {"exit_code": 1}),
            json.dumps(report() | {"action": "failed"}),
            json.dumps(report() | {"last_success_at": float("nan")}),
            '{"schema_version":1,"schema_version":1}',
            json.dumps(
                {
                    key: value
                    for key, value in report().items()
                    if key != "export_failed"
                }
            ),
        ]
        for raw in malformed:
            with self.subTest(raw=raw[:60]):
                self.input.write_text(raw)
                # Preserve malformed syntax/duplicate keys; refresh observed_at
                # on ordinary objects so validation reaches each bad field.
                raw_mode = raw in (
                    "",
                    PRIVATE,
                    "null",
                    "[]",
                    '{"schema_version":1,"schema_version":1}',
                )
                self.assertEqual(
                    self.run_collector(FIXTURE_RAW=str(int(raw_mode))).returncode, 1
                )
                values = self.metrics()
                self.assertEqual(values["status_available"], 0)
                self.assertEqual(values["export_failed"], 1)

    def test_future_and_stale_observation_and_future_checkpoint_are_rejected(self):
        for offset in ("60", "-60"):
            self.assertEqual(
                self.run_collector(FIXTURE_CLOCK_OFFSET=offset).returncode, 1
            )
            self.assertEqual(self.metrics()["status_available"], 0)
        for key in (
            "ingestion_started_at",
            "ingestion_finished_at",
            "export_finished_at",
        ):
            body = report()
            body["checkpoint"][key] = time.time() + 3600
            self.input.write_text(json.dumps(body))
            self.assertEqual(self.run_collector().returncode, 1)
            self.assertEqual(self.metrics()["status_available"], 0)
        for location, key in (
            ("last_attempt", "started_at"),
            ("last_attempt", "finished_at"),
        ):
            body = report()
            body[location][key] = time.time() + 3600
            self.input.write_text(json.dumps(body))
            self.assertEqual(self.run_collector().returncode, 1)
            self.assertEqual(self.metrics()["status_available"], 0)
        self.input.write_text(
            json.dumps(report() | {"last_success_at": time.time() + 3600})
        )
        self.assertEqual(self.run_collector().returncode, 1)
        self.assertEqual(self.metrics()["status_available"], 0)

    def test_private_process_errors_missing_cli_and_timeout_fail_closed(self):
        for env in ({"FIXTURE_RAW": "1", "FIXTURE_EXIT": "2"}, {"FIXTURE_SLEEP": "2"}):
            self.assertEqual(self.run_collector(**env).returncode, 1)
            self.assertEqual(self.metrics()["status_available"], 0)
        self.cli.unlink()
        self.assertEqual(self.run_collector().returncode, 1)
        self.assertEqual(self.metrics()["export_failed"], 1)

    def test_status_unavailable_cannot_be_success_even_with_zero_exit(self):
        self.input.write_text(
            json.dumps(
                report()
                | {
                    "status_available": False,
                    "action": "waiting",
                }
            )
        )
        self.assertEqual(self.run_collector().returncode, 1)
        self.assertEqual(self.metrics()["status_available"], 0)
        self.assertEqual(self.metrics()["export_failed"], 1)

    def test_atomic_replace_and_publication_failure_keep_previous_evidence(self):
        self.assertEqual(self.run_collector().returncode, 0)
        held = self.output.open()
        old = held.read()
        self.input.write_text(json.dumps(report() | {"export_failed": True}))
        self.assertEqual(self.run_collector().returncode, 1)
        held.seek(0)
        self.assertEqual(held.read(), old)
        held.close()
        self.assertEqual(self.metrics()["export_failed"], 1)
        self.output.unlink()
        self.output.mkdir()
        marker = self.output / "old-evidence"
        marker.write_text(old)
        self.assertEqual(self.run_collector().returncode, 1)
        self.assertEqual(marker.read_text(), old)


if __name__ == "__main__":
    unittest.main()
