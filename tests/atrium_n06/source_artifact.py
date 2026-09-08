"""Immutable accepted Whiskey source and compiled artifact custody for N06."""

import hashlib
import io
import json
import subprocess
import tarfile
from pathlib import Path

REVISION = "273cf414cac75276492ee849bb3ea257ce47f8de"
ARCHIVE_SHA256 = "86c19abf73fb825bbbb1cd032272fa4af97ea9dddacb413aab0f4cbc932785a5"


def sha256(body):
    return hashlib.sha256(body).hexdigest()


def immutable_source(repository):
    result = subprocess.run(
        ["git", "-C", str(repository), "archive", "--format=tar", REVISION],
        capture_output=True,
        timeout=60,
        check=False,
    )
    if result.returncode or sha256(result.stdout) != ARCHIVE_SHA256:
        raise RuntimeError("whiskey_archive_identity_mismatch")
    files = {}
    with tarfile.open(fileobj=io.BytesIO(result.stdout)) as archive:
        for member in archive.getmembers():
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise RuntimeError("whiskey_archive_path_invalid")
            if member.isfile() and not any(
                part.startswith(".env") for part in path.parts
            ):
                files[member.name] = archive.extractfile(member).read()
    return files


def materialize(files, destination):
    destination.mkdir(parents=True, exist_ok=True)
    for name, body in files.items():
        path = destination / name
        if path.is_symlink():
            raise RuntimeError("whiskey_source_symlink")
        if path.exists():
            if path.read_bytes() != body:
                raise RuntimeError("whiskey_materialized_source_changed")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(body)
    return destination


def source_hashes(files):
    return {
        name: sha256(body)
        for name, body in files.items()
        if name.startswith(("server/", "vendor/"))
        or name in ("package.json", "package-lock.json", "tsconfig.server.json")
    }


def verify_runtime(directory, files):
    receipt = json.loads((directory / "build.json").read_text())
    if (
        receipt.get("source_revision") != REVISION
        or receipt.get("source_archive_sha256") != ARCHIVE_SHA256
        or receipt.get("source_sha256") != source_hashes(files)
    ):
        raise RuntimeError("whiskey_runtime_source_mismatch")
    body = (directory / "whiskey.tar.gz").read_bytes()
    if sha256(body) != receipt["archive_sha256"]:
        raise RuntimeError("whiskey_runtime_archive_changed")
    actual = {}
    with tarfile.open(fileobj=io.BytesIO(body)) as archive:
        for member in archive.getmembers():
            if member.isfile():
                actual[member.name] = sha256(archive.extractfile(member).read())
    if actual != receipt["members_sha256"]:
        raise RuntimeError("whiskey_runtime_members_changed")
    for name, expected in receipt["compiled"].items():
        if actual.get(name) != expected["digest"]:
            raise RuntimeError("whiskey_compiled_source_changed")
    return receipt
