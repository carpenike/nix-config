"""Fixed-path staging helpers; no Settings discovery, secret logging or network bootstrap."""

from __future__ import annotations

import ipaddress
import json
import math
import os
import pwd
import subprocess
import sys
import uuid
from collections.abc import Mapping
from decimal import Decimal, InvalidOperation
from pathlib import Path
from urllib.parse import urlsplit

DATA = Path("/var/lib/homelab-mcp")
READER = Path("/run/finance-report-reader")
REPORTS = DATA / "finance-reports"
STAGING_DB = DATA / "finance-signal-staging/context.db"
PRODUCTION_DB = DATA / "finances-context.db"
PG_DSN = "postgresql:///homelab_finance?host=/run/postgresql&user=finance-report-reader"
SIGNAL_FIELDS = ("NUMBER", "GROUP_ID", "OPS_GROUP_ID", "BOT_UUID", "CAPTURE_SENDERS")


class InvalidInput(Exception):
    """Only fixed diagnostic names may cross the process boundary."""


def required(environ: Mapping[str, str], name: str, error: str) -> str:
    value = environ.get(name, "")
    if (
        not value.strip()
        or len(value) > 16384
        or any(ord(c) < 32 or ord(c) == 127 for c in value)
    ):
        raise InvalidInput(error)
    return value


def amount(environ: Mapping[str, str], suffix: str) -> float:
    error = f"invalid_{suffix.lower()}"
    raw = required(environ, f"HOMELAB_MCP_FINANCES_{suffix}", error)
    try:
        value = Decimal(raw)
        number = float(value)
        if (
            not value.is_finite()
            or not math.isfinite(number)
            or value < 0
            or value != value.quantize(Decimal("0.01"))
            or Decimal(str(number)) != value
        ):
            raise InvalidOperation
        return number
    except (InvalidOperation, ValueError, OverflowError):
        raise InvalidInput(error) from None


def native_inputs(environ: Mapping[str, str], directory: Path) -> tuple[dict, dict]:
    """Select explicit fields from the effective MCP environment, never copy it."""
    prefix = "HOMELAB_MCP_FINANCES_"
    sidecar = required(environ, prefix + "SIDECAR_BASE_URL", "invalid_sidecar_url")
    remote = required(environ, prefix + "REPO_URL", "invalid_docs_url")
    try:
        url = urlsplit(sidecar)
        if (
            url.scheme != "http"
            or not ipaddress.ip_address(url.hostname or "").is_loopback
            or url.username is not None
            or url.password is not None
            or url.path not in ("", "/")
            or url.query
            or url.fragment
            or url.port == 0
        ):
            raise ValueError
    except ValueError:
        raise InvalidInput("invalid_sidecar_url") from None
    try:
        url = urlsplit(remote)
        if (
            url.scheme != "https"
            or not url.hostname
            or any(c.isspace() for c in remote)
            or url.username is not None
            or url.password is not None
            or url.query
            or url.fragment
            or url.port == 0
        ):
            raise ValueError
    except ValueError:
        raise InvalidInput("invalid_docs_url") from None
    # The staging sandbox is intentionally fixed to the current canonical paths.
    for suffix, expected in (
        ("REPO_PATH", str(DATA / "finances")),
        ("CONTEXT_DB_PATH", str(PRODUCTION_DB)),
        ("INGEST_STATE_PATH", str(DATA / "finances-ingest/state.json")),
        ("CONFIG_PATH", ""),
    ):
        if environ.get(prefix + suffix, expected) != expected:
            raise InvalidInput("unsupported_" + suffix.lower())
    secrets = {
        "sidecar-token": required(
            environ, prefix + "SIDECAR_TOKEN", "missing_sidecar_token"
        ),
        "docs-token": required(environ, prefix + "REPO_TOKEN", "missing_docs_token"),
        "postgres-dsn": PG_DSN,
    }
    config = {
        "sidecar_base_url": sidecar.rstrip("/"),
        "sidecar_token_file": str(directory / "sidecar-token"),
        "postgres_dsn_file": str(directory / "postgres-dsn"),
        "pg_schema": "household_finance",
        "ingestion_state": str(DATA / "finances-ingest/state.json"),
        "docs_cache": str(REPORTS / "docs.git"),
        "canonical_docs_checkout": str(DATA / "finances"),
        "docs_remote": remote,
        "docs_ref": "refs/heads/main",
        "docs_token_file": str(directory / "docs-token"),
        "finance_config_file": None,
        "floor": amount(environ, "FLOOR"),
        "amazon_baseline": amount(environ, "AMAZON_BASELINE"),
        "buffer_floor": amount(environ, "BUFFER_FLOOR"),
    }
    return config, secrets


def private_directory(path: Path, owner: tuple[int, int]) -> int:
    """Open the fixed leaf without following symlinks; never recurse over MCP state."""
    path.mkdir(mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if info.st_uid not in (os.geteuid(), owner[0]):
            raise InvalidInput("unsafe_directory_owner")
        os.fchown(fd, *owner)
        os.fchmod(fd, 0o700)
        return fd
    except BaseException:
        os.close(fd)
        raise


def atomic_file(
    directory: int, name: str, content: str, mode: int, owner: tuple[int, int]
) -> None:
    pending = f".{name}.{uuid.uuid4().hex}"
    fd = os.open(
        pending,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=directory,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            os.fchown(stream.fileno(), *owner)
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(pending, name, src_dir_fd=directory, dst_dir_fd=directory)
    finally:
        try:
            os.unlink(pending, dir_fd=directory)
        except FileNotFoundError:
            pass


def project(
    environ: Mapping[str, str], directory: Path, owner: tuple[int, int]
) -> None:
    """Publish reader.json last; invalidate the previous projection even on bad input."""
    fd = private_directory(directory, owner)
    try:
        try:
            os.unlink("reader.json", dir_fd=fd)
        except FileNotFoundError:
            pass
        config, secrets = native_inputs(environ, directory)
        for name, content in secrets.items():
            atomic_file(fd, name, content, 0o400, owner)
        atomic_file(
            fd, "reader.json", json.dumps(config, allow_nan=False) + "\n", 0o600, owner
        )
    finally:
        os.close(fd)


def capture_environment(environ: Mapping[str, str], port: str) -> dict[str, str]:
    """Pass only transport coordinates; all mode/path gates are fixed, not dotenv-controlled."""
    if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:
        raise InvalidInput("invalid_signal_port")
    result = {
        f"HOMELAB_MCP_SIGNAL_{field}": required(
            environ, f"HOMELAB_MCP_SIGNAL_{field}", "missing_signal_" + field.lower()
        )
        for field in SIGNAL_FIELDS
    }
    result.update(
        HOMELAB_MCP_SIGNAL_BASE_URL=f"http://127.0.0.1:{port}",
        HOMELAB_MCP_SIGNAL_CAPTURE_ENABLED="true",
        HOMELAB_MCP_SIGNAL_CAPTURE_MODE="test",
        HOMELAB_MCP_SIGNAL_CAPTURE_TIMEZONE="America/New_York",
        HOMELAB_MCP_SIGNAL_CAPTURE_DB_PATH=str(STAGING_DB),
        HOMELAB_MCP_FINANCES_CONTEXT_DB_PATH=str(PRODUCTION_DB),
        HOMELAB_MCP_SIGNAL_CAPTURE_TEST_GROUP_ID=result[
            "HOMELAB_MCP_SIGNAL_OPS_GROUP_ID"
        ],
    )
    return result


def prepare(executable: str, kind: str, directory: Path) -> int:
    """Keep both successful and failed native JSON artifacts private, never in journald."""
    if kind not in ("daily", "weekly"):
        raise InvalidInput("invalid_report_kind")
    fd = private_directory(directory, (os.geteuid(), os.getegid()))
    name = f"{kind}-{uuid.uuid4().hex}.json"
    pending = f".{name}.partial"
    try:
        output = os.open(
            pending,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=fd,
        )
        with os.fdopen(output, "w+b") as stream:
            result = subprocess.run(
                [
                    executable,
                    "--kind",
                    kind,
                    "--native-config",
                    str(READER / "reader.json"),
                ],
                env={
                    key: os.environ[key]
                    for key in ("PATH", "SSL_CERT_FILE", "GIT_SSL_CAINFO")
                    if key in os.environ
                },
                stdin=subprocess.DEVNULL,
                stdout=stream,
                stderr=subprocess.DEVNULL,
                timeout=210,
                check=False,
            )
            stream.flush()
            os.fsync(stream.fileno())
            stream.seek(0)
            try:
                artifact = json.load(stream)
            except (ValueError, UnicodeError):
                raise InvalidInput("native_prepare_no_artifact") from None
            if (
                not isinstance(artifact, dict)
                or artifact.get("schema_version") != 1
                or artifact.get("kind") != kind
                or artifact.get("status") not in ("ready", "quiet", "failed")
                or result.returncode not in (0, 2)
                or (artifact["status"] == "failed") != (result.returncode == 2)
            ):
                raise InvalidInput("native_prepare_invalid_artifact")
        os.replace(pending, name, src_dir_fd=fd, dst_dir_fd=fd)
        return result.returncode
    finally:
        try:
            os.unlink(pending, dir_fd=fd)
        except FileNotFoundError:
            pass
        os.close(fd)


def main(argv: list[str]) -> int:
    try:
        os.umask(0o077)
        if argv == ["project"]:
            owner = pwd.getpwnam("homelab-mcp")
            project(os.environ, READER, (owner.pw_uid, owner.pw_gid))
            return 0
        if len(argv) == 3 and argv[0] == "capture":
            os.execve(
                argv[1], [argv[1], "listen"], capture_environment(os.environ, argv[2])
            )
        elif len(argv) == 3 and argv[0] == "prepare":
            return prepare(argv[1], argv[2], REPORTS / "artifacts")
        raise InvalidInput("invalid_arguments")
    except InvalidInput as exc:
        print(str(exc), file=sys.stderr)
    except Exception:
        # Exception messages can include credential contents or private paths.
        print("finance_staging_runtime_failed", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
