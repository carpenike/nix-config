"""Offline synthetic tests; no production files, credentials, services or sockets."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import sqlite3
import stat
import sys
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(
    os.environ.get(
        "FINANCE_STAGING_RUNTIME",
        str(
            Path(__file__).resolve().parents[2]
            / "hosts/forge/services/finance-signal/runtime.py"
        ),
    )
)
SPEC = importlib.util.spec_from_file_location("finance_staging", SOURCE)
assert SPEC is not None and SPEC.loader is not None
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


def inputs() -> dict[str, str]:
    return {
        "HOMELAB_MCP_FINANCES_SIDECAR_BASE_URL": "http://127.0.0.1:19210",
        "HOMELAB_MCP_FINANCES_SIDECAR_TOKEN": "synthetic-sidecar-token",
        "HOMELAB_MCP_FINANCES_REPO_URL": "https://example.invalid/fixture.git",
        "HOMELAB_MCP_FINANCES_REPO_TOKEN": "synthetic-docs-token",
        "HOMELAB_MCP_FINANCES_FLOOR": "101.13",
        "HOMELAB_MCP_FINANCES_AMAZON_BASELINE": "17.19",
        "HOMELAB_MCP_FINANCES_BUFFER_FLOOR": "23.29",
        "HOMELAB_MCP_EXPORT_PG_DSN": "do-not-copy-writer",
        "HOMELAB_MCP_POCKETID_CLIENT_SECRET": "do-not-copy-oauth",
        "HOMELAB_MCP_SIGNAL_NUMBER": "do-not-copy-signal",
    }


class RuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = (
            Path.cwd() / ".artifacts" / ("finance-signal-test-" + uuid.uuid4().hex)
        )
        self.root.mkdir(mode=0o700, parents=True)
        self.reader = self.root / "reader"
        self.owner = (os.geteuid(), os.getegid())

    def tearDown(self) -> None:
        shutil.rmtree(self.root)

    def test_projection_schema_modes_and_allowlist(self) -> None:
        runtime.project(inputs(), self.reader, self.owner)
        config = json.loads((self.reader / "reader.json").read_text())
        self.assertEqual(
            set(config),
            {
                "sidecar_base_url",
                "sidecar_token_file",
                "postgres_dsn_file",
                "pg_schema",
                "ingestion_state",
                "docs_cache",
                "canonical_docs_checkout",
                "docs_remote",
                "docs_ref",
                "docs_token_file",
                "finance_config_file",
                "floor",
                "amazon_baseline",
                "buffer_floor",
            },
        )
        self.assertEqual(
            config["docs_cache"], "/var/lib/homelab-mcp/finance-reports/docs.git"
        )
        self.assertEqual(
            config["canonical_docs_checkout"], "/var/lib/homelab-mcp/finances"
        )
        self.assertEqual(
            config["ingestion_state"], "/var/lib/homelab-mcp/finances-ingest/state.json"
        )
        self.assertIsNone(config["finance_config_file"])
        self.assertEqual(config["docs_ref"], "refs/heads/main")
        self.assertEqual(
            {p.name for p in self.reader.iterdir()},
            {"reader.json", "sidecar-token", "docs-token", "postgres-dsn"},
        )
        self.assertEqual(stat.S_IMODE(self.reader.stat().st_mode), 0o700)
        for path in self.reader.iterdir():
            self.assertEqual(path.stat().st_uid, self.owner[0])
            self.assertEqual(
                stat.S_IMODE(path.stat().st_mode),
                0o600 if path.name == "reader.json" else 0o400,
            )
            self.assertNotIn("do-not-copy", path.read_text())
        self.assertEqual((self.reader / "postgres-dsn").read_text(), runtime.PG_DSN)
        self.assertNotIn("password", runtime.PG_DSN)
        self.assertNotIn(
            "synthetic-sidecar-token", (self.reader / "reader.json").read_text()
        )
        self.assertNotIn(
            "synthetic-docs-token", (self.reader / "reader.json").read_text()
        )

    def test_reprojection_uses_current_values_and_rotated_tokens(self) -> None:
        env = inputs()
        runtime.project(env, self.reader, self.owner)
        env.update(
            HOMELAB_MCP_FINANCES_FLOOR="303.37",
            HOMELAB_MCP_FINANCES_AMAZON_BASELINE="41.43",
            HOMELAB_MCP_FINANCES_BUFFER_FLOOR="47.53",
            HOMELAB_MCP_FINANCES_SIDECAR_TOKEN="rotated-sidecar",
            HOMELAB_MCP_FINANCES_REPO_TOKEN="rotated-docs",
        )
        runtime.project(env, self.reader, self.owner)
        config = json.loads((self.reader / "reader.json").read_text())
        self.assertEqual(
            [config[k] for k in ("floor", "amazon_baseline", "buffer_floor")],
            [303.37, 41.43, 47.53],
        )
        self.assertEqual((self.reader / "sidecar-token").read_text(), "rotated-sidecar")
        self.assertEqual((self.reader / "docs-token").read_text(), "rotated-docs")

    def test_missing_required_input_invalidates_previous_config(self) -> None:
        for key in inputs():
            if "do-not-copy" in inputs()[key]:
                continue
            with self.subTest(key=key):
                env = inputs()
                runtime.project(env, self.reader, self.owner)
                del env[key]
                with self.assertRaises(runtime.InvalidInput):
                    runtime.project(env, self.reader, self.owner)
                self.assertFalse((self.reader / "reader.json").exists())

    def test_invalid_amounts_never_fall_back(self) -> None:
        for suffix in ("FLOOR", "AMAZON_BASELINE", "BUFFER_FLOOR"):
            for value in (
                "",
                "NaN",
                "Infinity",
                "-Infinity",
                "-1",
                "1.234",
                "1e9999",
                "secret-invalid",
            ):
                with self.subTest(suffix=suffix, value=value):
                    env = inputs() | {"HOMELAB_MCP_FINANCES_" + suffix: value}
                    with self.assertRaisesRegex(
                        runtime.InvalidInput, "^invalid_" + suffix.lower() + "$"
                    ):
                        runtime.project(env, self.reader, self.owner)
                    self.assertFalse((self.reader / "reader.json").exists())

    def test_unsafe_urls_and_path_overrides_are_rejected(self) -> None:
        cases = [
            ("SIDECAR_BASE_URL", "https://127.0.0.1:19210", "invalid_sidecar_url"),
            ("SIDECAR_BASE_URL", "http://example.invalid", "invalid_sidecar_url"),
            ("SIDECAR_BASE_URL", "http://token@127.0.0.1:19210", "invalid_sidecar_url"),
            (
                "SIDECAR_BASE_URL",
                "http://127.0.0.1:19210/bank-sync",
                "invalid_sidecar_url",
            ),
            (
                "REPO_URL",
                "https://private-token@example.invalid/repo",
                "invalid_docs_url",
            ),
            (
                "REPO_URL",
                "https://example.invalid/repo?token=private",
                "invalid_docs_url",
            ),
            ("REPO_URL", "https://example.invalid/ bad-url", "invalid_docs_url"),
            ("REPO_URL", "/local/fixture-is-not-runtime", "invalid_docs_url"),
            ("REPO_PATH", "/elsewhere", "unsupported_repo_path"),
            ("CONTEXT_DB_PATH", "/elsewhere", "unsupported_context_db_path"),
            ("INGEST_STATE_PATH", "/elsewhere", "unsupported_ingest_state_path"),
            ("CONFIG_PATH", "/elsewhere", "unsupported_config_path"),
        ]
        for suffix, value, error in cases:
            with self.subTest(suffix=suffix, value=value):
                with self.assertRaisesRegex(runtime.InvalidInput, "^" + error + "$"):
                    runtime.project(
                        inputs() | {"HOMELAB_MCP_FINANCES_" + suffix: value},
                        self.reader,
                        self.owner,
                    )

    def test_symlink_directory_is_not_followed(self) -> None:
        victim = self.root / "victim"
        victim.mkdir(mode=0o700)
        self.reader.symlink_to(victim, target_is_directory=True)
        with self.assertRaises(OSError):
            runtime.project(inputs(), self.reader, self.owner)
        self.assertEqual(list(victim.iterdir()), [])

    def test_empty_or_multiline_credentials_fail_without_outputs(self) -> None:
        for suffix in ("SIDECAR_TOKEN", "REPO_TOKEN"):
            for value in ("", "   ", "synthetic\ninjected", "synthetic\x7fvalue"):
                with self.subTest(suffix=suffix, value=value):
                    with self.assertRaises(runtime.InvalidInput):
                        runtime.project(
                            inputs() | {"HOMELAB_MCP_FINANCES_" + suffix: value},
                            self.reader,
                            self.owner,
                        )
                    self.assertFalse((self.reader / "reader.json").exists())

    def test_output_symlink_is_replaced_without_writing_target(self) -> None:
        victim = self.root / "unrelated"
        victim.write_text("unchanged")
        self.reader.mkdir(mode=0o700)
        (self.reader / "sidecar-token").symlink_to(victim)
        runtime.project(inputs(), self.reader, self.owner)
        self.assertEqual(victim.read_text(), "unchanged")
        self.assertFalse((self.reader / "sidecar-token").is_symlink())

    def test_cli_failure_prints_only_fixed_error(self) -> None:
        out, err = io.StringIO(), io.StringIO()
        env = inputs() | {"HOMELAB_MCP_FINANCES_FLOOR": "sensitive-invalid-value"}
        user = type("User", (), {"pw_uid": self.owner[0], "pw_gid": self.owner[1]})()
        with (
            patch.object(runtime, "READER", self.reader),
            patch.object(runtime.pwd, "getpwnam", return_value=user),
            patch.dict(os.environ, env, clear=True),
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
        ):
            self.assertEqual(runtime.main(["project"]), 2)
        self.assertEqual(out.getvalue(), "")
        self.assertEqual(err.getvalue(), "invalid_floor\n")

    def test_unexpected_failure_cannot_log_exception_contents(self) -> None:
        err = io.StringIO()
        with (
            patch.object(
                runtime.pwd,
                "getpwnam",
                side_effect=OSError("sensitive-unexpected-value"),
            ),
            contextlib.redirect_stderr(err),
        ):
            self.assertEqual(runtime.main(["project"]), 2)
        self.assertEqual(err.getvalue(), "finance_staging_runtime_failed\n")

    def test_capture_allowlist_and_fixed_mode_paths_ops_gate(self) -> None:
        env = {
            f"HOMELAB_MCP_SIGNAL_{key}": f"synthetic-{key}"
            for key in runtime.SIGNAL_FIELDS
        }
        env.update(inputs())
        env.update(
            HOMELAB_MCP_SIGNAL_CAPTURE_MODE="production",
            HOMELAB_MCP_SIGNAL_CAPTURE_ENABLED="false",
            HOMELAB_MCP_SIGNAL_CAPTURE_DB_PATH=str(runtime.PRODUCTION_DB),
            HOMELAB_MCP_SIGNAL_CAPTURE_TEST_GROUP_ID="family-override",
            HOMELAB_MCP_SIGNAL_BASE_URL="https://remote.invalid",
            HOMELAB_MCP_FINANCES_CONTEXT_DB_PATH="/elsewhere",
        )
        result = runtime.capture_environment(env, "18484")
        self.assertEqual(result["HOMELAB_MCP_SIGNAL_CAPTURE_MODE"], "test")
        self.assertEqual(result["HOMELAB_MCP_SIGNAL_CAPTURE_ENABLED"], "true")
        self.assertEqual(
            result["HOMELAB_MCP_SIGNAL_BASE_URL"], "http://127.0.0.1:18484"
        )
        self.assertEqual(
            result["HOMELAB_MCP_SIGNAL_CAPTURE_DB_PATH"],
            "/var/lib/homelab-mcp/finance-signal-staging/context.db",
        )
        self.assertEqual(
            result["HOMELAB_MCP_FINANCES_CONTEXT_DB_PATH"],
            "/var/lib/homelab-mcp/finances-context.db",
        )
        self.assertEqual(
            result["HOMELAB_MCP_SIGNAL_CAPTURE_TEST_GROUP_ID"],
            result["HOMELAB_MCP_SIGNAL_OPS_GROUP_ID"],
        )
        self.assertEqual(
            result["HOMELAB_MCP_SIGNAL_BOT_UUID"], env["HOMELAB_MCP_SIGNAL_BOT_UUID"]
        )
        self.assertEqual(
            result["HOMELAB_MCP_SIGNAL_CAPTURE_SENDERS"],
            env["HOMELAB_MCP_SIGNAL_CAPTURE_SENDERS"],
        )
        self.assertEqual(len(result), len(runtime.SIGNAL_FIELDS) + 7)
        self.assertNotIn("HOMELAB_MCP_FINANCES_SIDECAR_TOKEN", result)
        self.assertNotIn("HOMELAB_MCP_EXPORT_PG_DSN", result)

    def test_capture_missing_inputs_and_invalid_ports_fail_before_exec(self) -> None:
        env = {
            f"HOMELAB_MCP_SIGNAL_{key}": f"synthetic-{key}"
            for key in runtime.SIGNAL_FIELDS
        }
        for field in runtime.SIGNAL_FIELDS:
            with self.subTest(field=field):
                missing = dict(env)
                del missing[f"HOMELAB_MCP_SIGNAL_{field}"]
                with self.assertRaises(runtime.InvalidInput):
                    runtime.capture_environment(missing, "18484")
        for port in ("", "0", "65536", "8484/receive", "８４８４"):
            with self.subTest(port=port), self.assertRaises(runtime.InvalidInput):
                runtime.capture_environment(env, port)

    def test_capture_exec_does_not_inherit_any_other_environment(self) -> None:
        class ReplacedProcess(BaseException):
            pass

        env = {
            f"HOMELAB_MCP_SIGNAL_{key}": f"synthetic-{key}"
            for key in runtime.SIGNAL_FIELDS
        } | inputs()
        with (
            patch.dict(os.environ, env, clear=True),
            patch.object(runtime.os, "execve", side_effect=ReplacedProcess) as execute,
            self.assertRaises(ReplacedProcess),
        ):
            runtime.main(["capture", "/fixture/homelab-finances-signal", "18484"])
        executable, arguments, passed = execute.call_args.args
        self.assertEqual(executable, "/fixture/homelab-finances-signal")
        self.assertEqual(arguments, [executable, "listen"])
        self.assertEqual(passed, runtime.capture_environment(env, "18484"))

    def fake_producer(self, exit_code: int) -> Path:
        path = self.root / "native-producer"
        path.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "assert sys.argv[1:3] == ['--kind', 'daily']\n"
            "assert sys.argv[3:] == ['--native-config', '/run/finance-report-reader/reader.json']\n"
            "assert 'HOMELAB_MCP_POCKETID_CLIENT_SECRET' not in os.environ\n"
            "print(json.dumps({'schema_version': 1, 'kind': 'daily', 'status': "
            + repr("ready" if exit_code == 0 else "failed")
            + ", 'synthetic_private_fact': 123, 'exit': "
            + str(exit_code)
            + "}))\n"
            "print('synthetic-private-stderr', file=sys.stderr)\n"
            f"sys.exit({exit_code})\n"
        )
        path.chmod(0o700)
        return path

    def test_native_success_and_failure_artifacts_are_private_not_logged(self) -> None:
        artifacts = self.root / "artifacts"
        for code in (0, 2):
            out, err = io.StringIO(), io.StringIO()
            with (
                patch.dict(
                    os.environ, {"HOMELAB_MCP_POCKETID_CLIENT_SECRET": "never-forward"}
                ),
                contextlib.redirect_stdout(out),
                contextlib.redirect_stderr(err),
            ):
                self.assertEqual(
                    runtime.prepare(str(self.fake_producer(code)), "daily", artifacts),
                    code,
                )
            self.assertEqual(out.getvalue() + err.getvalue(), "")
        files = list(artifacts.iterdir())
        self.assertEqual(len(files), 2)
        self.assertEqual({json.loads(p.read_text())["exit"] for p in files}, {0, 2})
        self.assertEqual(stat.S_IMODE(artifacts.stat().st_mode), 0o700)
        for path in files:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertTrue(path.name.endswith(".json"))
        with self.assertRaisesRegex(runtime.InvalidInput, "^invalid_report_kind$"):
            runtime.prepare("unused", "family", artifacts)

    def test_native_input_error_does_not_publish_an_empty_artifact(self) -> None:
        producer = self.root / "empty-producer"
        producer.write_text(
            f"#!{sys.executable}\n"
            "import sys\n"
            "print('synthetic-private-stderr', file=sys.stderr)\n"
            "sys.exit(2)\n"
        )
        producer.chmod(0o700)
        with self.assertRaisesRegex(
            runtime.InvalidInput, "^native_prepare_no_artifact$"
        ):
            runtime.prepare(str(producer), "daily", self.root / "artifacts")
        self.assertEqual(list((self.root / "artifacts").iterdir()), [])

    def test_native_inconsistent_exit_is_not_published(self) -> None:
        producer = self.fake_producer(2)
        producer.write_text(producer.read_text().replace("sys.exit(2)", "sys.exit(0)"))
        with self.assertRaisesRegex(
            runtime.InvalidInput, "^native_prepare_invalid_artifact$"
        ):
            runtime.prepare(str(producer), "daily", self.root / "artifacts")
        self.assertEqual(list((self.root / "artifacts").iterdir()), [])

    def test_configuration_stage_leaves_existing_nine_row_context_untouched(
        self,
    ) -> None:
        context = self.root / "finances-context.db"
        with sqlite3.connect(context) as db:
            db.execute("CREATE TABLE context (id INTEGER PRIMARY KEY, note TEXT)")
            db.executemany(
                "INSERT INTO context VALUES (?, ?)",
                [(i, "synthetic-note") for i in range(9)],
            )
        context.chmod(0o644)
        self.assertEqual(stat.S_IMODE(self.root.stat().st_mode), 0o700)
        before = (
            hashlib.sha256(context.read_bytes()).digest(),
            context.stat().st_mtime_ns,
            stat.S_IMODE(context.stat().st_mode),
        )
        runtime.project(inputs(), self.reader, self.owner)
        runtime.capture_environment(
            {
                f"HOMELAB_MCP_SIGNAL_{key}": f"synthetic-{key}"
                for key in runtime.SIGNAL_FIELDS
            },
            "18484",
        )
        self.assertEqual(
            (
                hashlib.sha256(context.read_bytes()).digest(),
                context.stat().st_mtime_ns,
                stat.S_IMODE(context.stat().st_mode),
            ),
            before,
        )
        self.assertFalse((self.root / "finance-signal-staging").exists())
        with sqlite3.connect(f"file:{context}?mode=ro", uri=True) as db:
            self.assertEqual(
                db.execute("SELECT count(*) FROM context").fetchone()[0], 9
            )


if __name__ == "__main__":
    unittest.main()
