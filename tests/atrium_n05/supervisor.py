"""Load only the explicitly pinned N07 orchestration, never current R06 work."""

import hashlib
import importlib
import json
import subprocess
import sys
from pathlib import Path

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
