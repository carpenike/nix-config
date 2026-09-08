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


@contextmanager
def publication_directory(path: Path, group: int):
    require(
        path.is_absolute()
        and ".." not in path.parts
        and type(group) is int
        and 0 <= group < 2**32 - 1
        and group in {os.getegid(), *os.getgroups()},
        "invalid_publication_group",
    )
    with directory(path, secret=True) as parent:
        info = os.fstat(parent)
        require(
            info.st_uid == os.geteuid()
            and info.st_gid == group
            and stat.S_IMODE(info.st_mode) == 0o2750,
            "untrusted_publication_directory",
        )
        yield parent


def _publication_existing(parent: int, name: str, group: int) -> bytes | None:
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=parent,
        )
    except FileNotFoundError:
        return None
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        require(
            stat.S_ISREG(before.st_mode)
            and before.st_nlink == 1
            and before.st_uid == os.geteuid()
            and before.st_gid == group
            and stat.S_IMODE(before.st_mode) == 0o640
            and before.st_size <= MAX_DOCUMENT,
            "untrusted_publication_file",
        )
        body = stream.read(MAX_DOCUMENT + 1)
        after = os.fstat(stream.fileno())
        require(
            len(body) <= MAX_DOCUMENT
            and (before.st_ino, before.st_size, before.st_mtime_ns)
            == (after.st_ino, after.st_size, after.st_mtime_ns),
            "publication_changed_during_read",
        )
    decode(body)
    return body


def validate_publication(path: Path, group: int) -> None:
    try:
        with publication_directory(path.parent, group) as parent:
            _publication_existing(parent, path.name, group)
    except OSError:
        raise ControllerError("protected_publication_unavailable") from None


def atomic_publication_json(path: Path, value: dict, group: int) -> None:
    require(
        value.get("kind") in {"atrium.litellm-bindings", "atrium.litellm-associations"},
        "invalid_publication_kind",
    )
    atomic_json(path, value, secret=True, mode=0o640, group=group, publication=True)


def atomic_json(
    path: Path,
    value: dict,
    *,
    secret: bool = False,
    mode: int = 0o600,
    group: int | None = None,
    publication: bool = False,
) -> None:
    require(mode in (0o600, 0o640), "unsafe_publication_mode")
    payload = canonical(value) + b"\n"
    if publication:
        require(
            mode == 0o640 and len(payload) <= MAX_DOCUMENT, "invalid_publication_mode"
        )
    opened = (
        publication_directory(path.parent, group)
        if publication
        else directory(path.parent, secret=secret)
    )
    with opened as parent:
        previous = (
            _publication_existing(parent, path.name, group) if publication else None
        )
        if publication and previous == payload:
            return
        staged = "." + path.name + "." + secrets.token_hex(12) + ".next"
        try:
            fd = os.open(
                staged,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600 if publication else mode,
                dir_fd=parent,
            )
            with os.fdopen(fd, "wb") as stream:
                if not publication:
                    os.fchmod(stream.fileno(), mode)
                    if group is not None:
                        os.fchown(stream.fileno(), -1, group)
                stream.write(payload)
                stream.flush()
                if publication:
                    os.fchown(stream.fileno(), -1, group)
                    os.fchmod(stream.fileno(), mode)
                    staged_info = os.fstat(stream.fileno())
                    require(
                        stat.S_ISREG(staged_info.st_mode)
                        and staged_info.st_nlink == 1
                        and staged_info.st_uid == os.geteuid()
                        and staged_info.st_gid == group
                        and stat.S_IMODE(staged_info.st_mode) == 0o640,
                        "publication_staging_changed",
                    )
                os.fsync(stream.fileno())
            if publication:
                with publication_directory(path.parent, group) as current:
                    require(
                        (os.fstat(parent).st_dev, os.fstat(parent).st_ino)
                        == (os.fstat(current).st_dev, os.fstat(current).st_ino),
                        "publication_directory_changed",
                    )
                require(
                    _publication_existing(parent, path.name, group) == previous,
                    "publication_changed_during_write",
                )
                current = os.stat(staged, dir_fd=parent, follow_symlinks=False)
                require(
                    (
                        staged_info.st_dev,
                        staged_info.st_ino,
                        staged_info.st_size,
                        staged_info.st_mtime_ns,
                    )
                    == (
                        current.st_dev,
                        current.st_ino,
                        current.st_size,
                        current.st_mtime_ns,
                    )
                    and current.st_nlink == 1
                    and stat.S_ISREG(current.st_mode)
                    and current.st_uid == os.geteuid()
                    and current.st_gid == group
                    and stat.S_IMODE(current.st_mode) == 0o640,
                    "publication_staging_changed",
                )
            os.replace(staged, path.name, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
        except OSError:
            raise ControllerError("atomic_publication_failed") from None
        finally:
            try:
                os.unlink(staged, dir_fd=parent)
            except FileNotFoundError:
                pass
