import hashlib
import json
import os
import secrets
import stat
from contextlib import contextmanager
from pathlib import Path

from .errors import ControllerError, require

MAX_DOCUMENT = 8 * 1024 * 1024


def canonical(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode()


def digest(value: object) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def decode(data: bytes) -> dict:
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate_json_field")
            result[key] = value
        return result

    def invalid_constant(_):
        raise ControllerError("nonfinite_json_number")

    try:
        value = json.loads(
            data, object_pairs_hook=pairs, parse_constant=invalid_constant
        )
    except (ValueError, UnicodeError, RecursionError):
        raise ControllerError("invalid_json") from None
    require(isinstance(value, dict), "invalid_document")
    return value


@contextmanager
def directory(path: Path, *, trusted_uid: int | None = None, secret: bool = False):
    path = Path(os.path.abspath(path))
    require(".." not in path.parts, "invalid_path")
    require(not str(path).startswith("/nix/store"), "store_state_refused")
    owners = {0, os.geteuid(), os.geteuid() if trusted_uid is None else trusted_uid}
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            next_fd = os.open(
                part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
            )
            os.close(fd)
            fd = next_fd
            info = os.fstat(fd)
            require(
                info.st_uid in owners and not info.st_mode & 0o022,
                "untrusted_directory",
            )
            if secret:
                for marker in (".git", ".hg"):
                    try:
                        os.stat(marker, dir_fd=fd, follow_symlinks=False)
                    except FileNotFoundError:
                        continue
                    raise ControllerError("repository_secret_refused")
        yield fd
    except OSError:
        raise ControllerError("protected_directory_unavailable") from None
    finally:
        os.close(fd)


def read_bytes(
    path: Path,
    *,
    uid: int | None = None,
    secret: bool = False,
    limit: int = MAX_DOCUMENT,
) -> bytes:
    uid = os.geteuid() if uid is None else uid
    with directory(path.parent, trusted_uid=uid, secret=secret) as parent:
        try:
            fd = os.open(
                path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent
            )
            with os.fdopen(fd, "rb") as stream:
                before = os.fstat(stream.fileno())
                require(
                    stat.S_ISREG(before.st_mode)
                    and before.st_uid == uid
                    and before.st_nlink == 1
                    and not before.st_mode & 0o027
                    and before.st_size <= limit,
                    "untrusted_file",
                )
                content = stream.read(limit + 1)
                after = os.fstat(stream.fileno())
                require(
                    len(content) <= limit
                    and (before.st_ino, before.st_size, before.st_mtime_ns)
                    == (after.st_ino, after.st_size, after.st_mtime_ns),
                    "file_changed_during_read",
                )
                return content
        except OSError:
            raise ControllerError("protected_file_unavailable") from None


def read_json(path: Path, *, uid: int | None = None, secret: bool = False) -> dict:
    return decode(read_bytes(path, uid=uid, secret=secret))


def atomic_json(
    path: Path,
    value: dict,
    *,
    secret: bool = False,
    mode: int = 0o600,
    group: int | None = None,
) -> None:
    require(mode in (0o600, 0o640), "unsafe_publication_mode")
    payload = canonical(value) + b"\n"
    with directory(path.parent, secret=secret) as parent:
        staged = "." + path.name + "." + secrets.token_hex(12) + ".next"
        try:
            fd = os.open(
                staged,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                mode,
                dir_fd=parent,
            )
            with os.fdopen(fd, "wb") as stream:
                os.fchmod(stream.fileno(), mode)
                if group is not None:
                    os.fchown(stream.fileno(), -1, group)
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(staged, path.name, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
        except OSError:
            raise ControllerError("atomic_publication_failed") from None
        finally:
            try:
                os.unlink(staged, dir_fd=parent)
            except FileNotFoundError:
                pass
