import importlib.util
from contextlib import redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import stat
import subprocess
import unittest
from unittest.mock import mock_open, patch


MODULE = Path(os.environ["AGENT_HOST_MODULE"])


def load(name):
    spec = importlib.util.spec_from_file_location(name, MODULE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


preflight = load("preflight")
health = load("healthcheck")


class PreflightTests(unittest.TestCase):
    def token(self, contents, mode=stat.S_IFREG | 0o400):
        with (
            patch.object(preflight.os, "stat") as info,
            patch("builtins.open", mock_open(read_data=contents)),
        ):
            info.return_value.st_mode = mode
            preflight.validate_token("/run/credentials/test/token")

    def test_private_url_safe_token(self):
        self.token(b"x" * 64)
        self.token(b"x" * 64 + b"\n")

    def test_rejects_missing_weak_multiline_or_non_url_safe_tokens(self):
        for token in [b"", b"short", b"x" * 257, b"x" * 64 + b"\n\n", b"x" * 63 + b"+"]:
            with (
                self.subTest(token_length=len(token)),
                self.assertRaises(preflight._ValidationFailure) as error,
            ):
                self.token(token)
            self.assertEqual(error.exception.code, "TOKEN_FORMAT")

    def test_rejects_shared_file_and_symlink(self):
        for mode in [stat.S_IFREG | 0o644, stat.S_IFREG | 0o440, stat.S_IFLNK | 0o400]:
            with (
                self.subTest(mode=mode),
                self.assertRaises(preflight._ValidationFailure) as error,
            ):
                self.token(b"x" * 64, mode)
            self.assertEqual(error.exception.code, "TOKEN_PERMISSIONS")

    def test_supported_cli(self):
        outputs = [
            subprocess.CompletedProcess([], 0, "code 1.139.1 (commit test)"),
            subprocess.CompletedProcess(
                [], 0, "Usage: code agent host " + " ".join(preflight.REQUIRED_FLAGS)
            ),
            subprocess.CompletedProcess([], 0, "--json"),
        ]
        with patch.object(preflight.subprocess, "run", side_effect=outputs):
            preflight.validate_cli("code", "1.139.1")

    def test_legacy_cli_help_exit_zero_is_not_support(self):
        outputs = [
            subprocess.CompletedProcess([], 0, "code 1.139.1 (commit test)"),
            subprocess.CompletedProcess([], 0, "Usage: code [options]"),
        ]
        with (
            patch.object(preflight.subprocess, "run", side_effect=outputs),
            self.assertRaises(preflight._ValidationFailure) as error,
        ):
            preflight.validate_cli("code", "1.139.1")
        self.assertEqual(error.exception.code, "UNSUPPORTED_CLI")

    def test_wrong_version_and_failed_command(self):
        with (
            patch.object(
                preflight.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 0, "code 1.1.0"),
            ),
            self.assertRaises(ValueError),
        ):
            preflight.validate_cli("code", "1.139.1")
        with (
            patch.object(
                preflight.subprocess,
                "run",
                side_effect=subprocess.CalledProcessError(1, "code"),
            ),
            self.assertRaises(subprocess.CalledProcessError),
        ):
            preflight.validate_cli("code", "1.139.1")

    def test_failure_codes_do_not_expose_exception_or_subprocess_details(self):
        private = "fixture-only-private-token-and-path"
        command = ["/private/fixture-cli", private]
        failures = [
            (
                "token",
                preflight._ValidationFailure("TOKEN_PERMISSIONS"),
                "TOKEN_PERMISSIONS",
            ),
            ("token", preflight._ValidationFailure("TOKEN_FORMAT"), "TOKEN_FORMAT"),
            ("token", FileNotFoundError(private), "TOKEN_UNAVAILABLE"),
            ("token", PermissionError(private), "TOKEN_UNAVAILABLE"),
            ("cli", FileNotFoundError(private), "CLI_UNAVAILABLE"),
            (
                "cli",
                subprocess.TimeoutExpired(command, 10, output=private, stderr=private),
                "CLI_TIMEOUT",
            ),
            (
                "cli",
                subprocess.CalledProcessError(
                    1, command, output=private, stderr=private
                ),
                "CLI_QUERY_FAILED",
            ),
            (
                "cli",
                preflight._ValidationFailure("CLI_VERSION_MISMATCH"),
                "CLI_VERSION_MISMATCH",
            ),
            ("cli", preflight._ValidationFailure("UNSUPPORTED_CLI"), "UNSUPPORTED_CLI"),
            ("cli", ValueError(private), "CLI_INVALID_OUTPUT"),
        ]
        argv = [
            "preflight",
            "--executable",
            private,
            "--version",
            "1.139.1",
            "--token-file",
            private,
        ]
        for stage, failure, code in failures:
            output = io.StringIO()
            with (
                self.subTest(code=code),
                patch.object(preflight.sys, "argv", argv),
                patch.object(
                    preflight,
                    "validate_token",
                    side_effect=failure if stage == "token" else None,
                ),
                patch.object(
                    preflight,
                    "validate_cli",
                    side_effect=failure if stage == "cli" else None,
                ),
                redirect_stderr(output),
                redirect_stdout(output),
            ):
                self.assertEqual(preflight.main(), 1)
            self.assertIn(
                f"[{code}]: {preflight.FAILURE_REASONS[code]}", output.getvalue()
            )
            self.assertNotIn(private, output.getvalue())
            self.assertNotIn("/private/fixture-cli", output.getvalue())


class HealthTests(unittest.TestCase):
    def result(self, **changes):
        result = {
            "host": {"type": "standalone", "address": "127.0.0.1:17890"},
            "sessions": [],
        }
        result.update(changes)
        return result

    def test_empty_authenticated_host_is_transport_ready(self):
        self.assertTrue(health.valid_status([self.result()], 17890))

    def test_missing_malformed_partial_or_competing_hosts_are_not_ready(self):
        cases = [
            [],
            {},
            [None],
            [self.result(), self.result()],
            [self.result(error="failed")],
            [self.result(sessions=None)],
            [self.result(host={"type": "editor", "address": "127.0.0.1:17890"})],
            [self.result(host={"type": "standalone", "address": "0.0.0.0:17890"})],
            [self.result(host={"type": "standalone", "address": "127.0.0.1:17891"})],
        ]
        for value in cases:
            with self.subTest(value=value):
                self.assertFalse(health.valid_status(value, 17890))

    def test_probe_never_puts_credential_or_session_payload_in_argv(self):
        with patch.object(health.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess(
                [],
                0,
                '[{"host":{"type":"standalone","address":"127.0.0.1:17890"},"sessions":[]}]',
            )
            self.assertTrue(
                health.probe("code", "/var/lib/vscode-agent-host", 17890, 10)
            )
            command = run.call_args.args[0]
            self.assertNotIn("--address", command)
            self.assertNotIn("--connection-token", command)
            self.assertEqual(run.call_args.kwargs["stdin"], subprocess.DEVNULL)
            self.assertEqual(run.call_args.kwargs["timeout"], 10)

    def test_failure_codes_hide_query_output_and_private_state(self):
        private = "fixture-only-private-token-and-path"
        command = ["/private/fixture-cli", private]
        cases = [
            (
                subprocess.TimeoutExpired(command, 10, output=private, stderr=private),
                "TIMEOUT",
            ),
            (
                subprocess.CalledProcessError(
                    1, command, output=private, stderr=private
                ),
                "STATUS_QUERY_FAILED",
            ),
            (PermissionError(private), "CLI_UNAVAILABLE"),
            (
                subprocess.CompletedProcess(command, 0, private, private),
                "INVALID_STATUS",
            ),
            (
                subprocess.CompletedProcess(
                    command, 0, '{"token":"' + private + '"}', private
                ),
                "INVALID_STATUS",
            ),
        ]
        argv = [
            "health",
            "--executable",
            private,
            "--data-dir",
            private,
            "--port",
            "17890",
        ]
        for outcome, code in cases:
            output = io.StringIO()
            with (
                self.subTest(code=code),
                patch.object(health.sys, "argv", argv),
                patch.object(
                    health.subprocess,
                    "run",
                    side_effect=outcome if isinstance(outcome, Exception) else None,
                    return_value=outcome,
                ),
                redirect_stderr(output),
                redirect_stdout(output),
            ):
                self.assertEqual(health.main(), 1)
            self.assertIn(
                f"[{code}]: {health.FAILURE_REASONS[code]}", output.getvalue()
            )
            self.assertNotIn(private, output.getvalue())
            self.assertNotIn("/private/fixture-cli", output.getvalue())

    def test_retries_report_latest_failure_and_recovery_returns_success(self):
        argv = [
            "health",
            "--executable",
            "code",
            "--data-dir",
            "/fixture",
            "--port",
            "17890",
            "--attempts",
            "2",
        ]
        for final_probe, expected_exit in [(False, 1), (True, 0)]:
            output = io.StringIO()
            with (
                self.subTest(final_probe=final_probe),
                patch.object(health.sys, "argv", argv),
                patch.object(
                    health,
                    "probe",
                    side_effect=[subprocess.TimeoutExpired("code", 10), final_probe],
                ),
                patch.object(health.time, "sleep"),
                redirect_stderr(output),
                redirect_stdout(output),
            ):
                self.assertEqual(health.main(), expected_exit)
            self.assertNotIn("[TIMEOUT]", output.getvalue())
            if expected_exit:
                self.assertIn("[INVALID_STATUS]", output.getvalue())
            else:
                self.assertIn("transport ready", output.getvalue())
                self.assertNotIn("failed", output.getvalue())


if __name__ == "__main__":
    unittest.main()
