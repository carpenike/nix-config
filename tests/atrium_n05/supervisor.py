"""Load only the explicitly pinned N07 orchestration, never current R06 work."""

import base64
import hashlib
import importlib
import io
import json
import subprocess
import sys
import tarfile
from pathlib import Path
from zipfile import BadZipFile, ZipFile

ROOT = Path(__file__).resolve().parents[2]
HARNESS_REVISION = "5eb22c6e5e0e9308f9b177471775ac71d8ae5ed8"
SHARED_FILES = (
    "__init__.py",
    "common.py",
    "containers.py",
    "litellm_native.py",
    "provider.py",
    "pins.json",
)


def git(repository, *args):
    result = subprocess.run(
        ["git", "-C", str(repository), *args],
        capture_output=True,
        timeout=60,
        check=False,
    )
    if result.returncode:
        raise RuntimeError("pinned_source_unavailable")
    return result.stdout


def load_harness(repository):
    root = ROOT / ".artifacts/n05-shared" / HARNESS_REVISION
    (root / "harness").mkdir(parents=True, exist_ok=True)
    hashes = {}
    for name in SHARED_FILES:
        body = git(repository, "show", HARNESS_REVISION + ":harness/" + name)
        (root / "harness" / name).write_bytes(body)
        hashes[name] = hashlib.sha256(body).hexdigest()
    sys.path.insert(0, str(root))
    native = importlib.import_module("harness.litellm_native")
    if Path(native.__file__).resolve() != root / "harness/litellm_native.py":
        raise RuntimeError("shared_harness_import_mismatch")
    return native, hashes


def inventory(resources):
    rows = {}
    for line in resources.command(
        ["ps", "--all", "--format", "{{.ID}}|{{.Names}}|{{.State}}"]
    ).splitlines():
        values = line.split("|")
        if len(values) == 3:
            rows[values[0]] = {"name": values[1], "state": values[2]}
    return rows


def verified_wheels(repository, revision):
    expected = {}
    archived = git(repository, "archive", revision, "profiles/src", "resolver/src")
    with tarfile.open(fileobj=io.BytesIO(archived)) as sources:
        for member in sources.getmembers():
            for prefix in ("profiles/src/", "resolver/src/"):
                if member.isfile() and member.name.startswith(prefix):
                    expected[member.name.removeprefix(prefix)] = sources.extractfile(
                        member
                    ).read()
    for directory in ("atrium-litellm-admission", "atrium-litellm-controller"):
        package = ROOT / "pkgs" / directory
        for path in package.rglob("*"):
            if (
                path.is_file()
                and "__pycache__" not in path.parts
                and path.suffix != ".pyc"
            ):
                relative = str(path.relative_to(package))
                if relative.startswith(("atrium_admission/", "atrium_litellm/")):
                    expected[relative] = path.read_bytes()
    paths = sorted((ROOT / ".artifacts/admission-wheels").glob("*.whl"))
    if len(paths) != 4:
        raise RuntimeError("actual_admission_wheels_missing")
    seen, encoded, hashes = set(), {}, {}
    for path in paths:
        content = path.read_bytes()
        metadata = path.name.split("-")[:2]
        metadata_directory = "-".join(metadata) + ".dist-info"
        try:
            with ZipFile(io.BytesIO(content)) as wheel:
                for name in wheel.namelist():
                    if name.endswith("/"):
                        continue
                    if name in expected:
                        if name in seen or wheel.read(name) != expected[name]:
                            raise RuntimeError("actual_wheel_source_mismatch")
                        seen.add(name)
                    elif (
                        len(parts := name.split("/")) != 2
                        or parts[0] != metadata_directory
                        or parts[1]
                        not in {
                            "METADATA",
                            "WHEEL",
                            "RECORD",
                            "entry_points.txt",
                            "top_level.txt",
                        }
                    ):
                        raise RuntimeError("actual_wheel_source_mismatch")
        except BadZipFile:
            raise RuntimeError("invalid_native_wheel") from None
        encoded[path.name] = base64.b64encode(content).decode()
        hashes[path.name] = hashlib.sha256(content).hexdigest()
    if seen != expected.keys():
        raise RuntimeError("actual_wheel_source_incomplete")
    return encoded, hashes


def ready(resources):
    resources.select_local_engine()
    before = inventory(resources)
    if any(
        row["state"] == "running" and row["name"] != "ambit-db"
        for row in before.values()
    ):
        raise RuntimeError("shared_native_vm_busy")
    return before


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
