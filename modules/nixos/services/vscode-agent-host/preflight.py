"""Fail closed before exposing the pinned standalone Agent Host."""

import argparse
import os
import re
import stat
import subprocess
import sys


REQUIRED_FLAGS = (
    "--host",
    "--port",
    "--connection-token-file",
    "--server-data-dir",
    "--user-data-dir",
    "--foreground",
    "--new-instance",
)

FAILURE_REASONS = {
    "TOKEN_UNAVAILABLE": "connection credential is missing or unreadable",
    "TOKEN_PERMISSIONS": "connection credential must be a private regular file",
    "TOKEN_FORMAT": "connection credential must contain one 32-256 character URL-safe token",
    "CLI_UNAVAILABLE": "pinned CLI is unavailable or cannot be executed",
    "CLI_TIMEOUT": "CLI version or capability check timed out",
    "CLI_QUERY_FAILED": "CLI version or capability check returned an error",
    "CLI_VERSION_MISMATCH": "CLI version does not match the configured pin",
    "UNSUPPORTED_CLI": "CLI lacks the required standalone host or authenticated status command",
    "CLI_INVALID_OUTPUT": "CLI version or capability output could not be interpreted",
}


class _ValidationFailure(ValueError):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def validate_token(path):
    info = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
        raise _ValidationFailure("TOKEN_PERMISSIONS")
    with open(path, "rb") as credential:
        token = credential.read(258)
    if not re.fullmatch(rb"[A-Za-z0-9_-]{32,256}\n?", token):
        raise _ValidationFailure("TOKEN_FORMAT")


def validate_cli(executable, version):
    def output(*args):
        result = subprocess.run(
            [executable, *args], capture_output=True, text=True, timeout=10, check=True
        )
        return result.stdout

    if version not in output("--version").split():
        raise _ValidationFailure("CLI_VERSION_MISMATCH")
    help_text = output("agent", "host", "--help")
    if "agent host" not in help_text or any(
        flag not in help_text for flag in REQUIRED_FLAGS
    ):
        raise _ValidationFailure("UNSUPPORTED_CLI")
    if "--json" not in output("agent", "ps", "--help"):
        raise _ValidationFailure("UNSUPPORTED_CLI")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--token-file", required=True)
    args = parser.parse_args()
    stage = "TOKEN"
    try:
        validate_token(args.token_file)
        stage = "CLI"
        validate_cli(args.executable, args.version)
    except _ValidationFailure as error:
        code = error.code
    except subprocess.TimeoutExpired:
        code = "CLI_TIMEOUT"
    except subprocess.SubprocessError:
        code = "CLI_QUERY_FAILED"
    except OSError:
        code = f"{stage}_UNAVAILABLE"
    except ValueError:
        code = "TOKEN_UNAVAILABLE" if stage == "TOKEN" else "CLI_INVALID_OUTPUT"
    else:
        return 0
    # Only allowlisted constants, never exception text, paths or CLI output.
    print(
        f"Agent Host preflight failed [{code}]: {FAILURE_REASONS[code]}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
