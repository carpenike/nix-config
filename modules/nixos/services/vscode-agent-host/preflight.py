"""Fail closed before exposing the pinned standalone Agent Host."""

import argparse
import os
import re
import stat
import struct
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


def _private_systemd_acl(path, access):
    try:
        acl = os.getxattr(path, "system.posix_acl_access", follow_symlinks=False)
    except (AttributeError, OSError):
        return False
    # Linux ACL xattr v2: root owner, this service UID, empty owning group,
    # access mask, empty other. Reject extra principals, even with safe mode bits.
    undefined_id = 0xFFFFFFFF
    expected = {
        (0x01, access, undefined_id),
        (0x02, access, os.geteuid()),
        (0x04, 0, undefined_id),
        (0x10, access, undefined_id),
        (0x20, 0, undefined_id),
    }
    return (
        len(acl) == 44
        and struct.unpack_from("<I", acl)[0] == 2
        and set(struct.iter_unpack("<HHI", acl[4:])) == expected
    )


def _is_private_systemd_credential(path, info):
    directory = os.environ.get("CREDENTIALS_DIRECTORY")
    path = os.fspath(path)
    if (
        not directory
        or os.path.dirname(directory) != "/run/credentials"
        or os.path.normpath(directory) != directory
        or os.path.normpath(path) != path
        or os.path.dirname(path) != directory
        or (info.st_uid, info.st_gid) != (0, 0)
        or stat.S_IMODE(info.st_mode) != 0o440
    ):
        return False
    directory_info = os.stat(directory, follow_symlinks=False)
    return (
        stat.S_ISDIR(directory_info.st_mode)
        and stat.S_IMODE(directory_info.st_mode) == 0o550
        and (directory_info.st_uid, directory_info.st_gid) == (0, 0)
        and _private_systemd_acl(directory, 0o5)
        and _private_systemd_acl(path, 0o4)
    )


def validate_token(path):
    info = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(info.st_mode) or (
        info.st_mode & 0o077 and not _is_private_systemd_credential(path, info)
    ):
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
