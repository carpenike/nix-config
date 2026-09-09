"""Verify accepted service payloads before sending public code to the isolated runtime."""

import hashlib
import io
import json
import subprocess
from email.parser import BytesParser
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]


def checksum(body):
    return {"algorithm": "sha256", "digest": hashlib.sha256(body).hexdigest()}


def zip_files(files):
    stream = io.BytesIO()
    with ZipFile(stream, "w") as archive:
        for name, body in files.items():
            archive.writestr(name, body)
    return stream.getvalue()


def wheel_files(path):
    with ZipFile(path) as archive:
        return {
            name: archive.read(name)
            for name in archive.namelist()
            if not name.endswith("/")
        }


def verified_payloads():
    inputs = json.loads((ROOT / ".artifacts/n03-inputs.json").read_text())
    actual = json.loads(
        subprocess.run(
            [
                "nix",
                "eval",
                "--builders",
                "",
                "--no-write-lock-file",
                "--impure",
                "--json",
                "--expr",
                f'let f = builtins.getFlake "{ROOT}"; in builtins.mapAttrs (_: v: {{ path = toString v; rev = v.rev or null; }}) {{ inherit (f.inputs) atrium homelab-mcp whiskey-whiskey-whiskey; }}',
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    )
    if inputs != actual:
        raise ValueError("artifact_inputs_differ_from_actual_flake")
    pins = json.loads((ROOT / "tests/atrium_n03/pins.json").read_text())
    for name, key in (
        ("atrium", "atrium"),
        ("homelab-mcp", "native"),
        ("whiskey-whiskey-whiskey", "consumer"),
    ):
        if inputs[name]["rev"] != pins[key]:
            raise ValueError("unaccepted_input")
    atrium = Path(inputs["atrium"]["path"])
    native = Path(inputs["homelab-mcp"]["path"])
    resolver_files = {}
    fingerprints = {}
    for package in ("profiles", "resolver", "sidecar"):
        wheel = (
            ROOT / ".artifacts/n03-wheels" / f"atrium_{package}-0.1.0-py3-none-any.whl"
        )
        files = wheel_files(wheel)
        expected = {
            str(path.relative_to(atrium / package / "src")): path.read_bytes()
            for path in (atrium / package / "src").rglob("*")
            if path.is_file()
        }
        shipped = {
            name: body
            for name, body in files.items()
            if name.startswith(f"atrium_{package}/")
        }
        if shipped != expected:
            raise ValueError("atrium_wheel_source_mismatch")
        resolver_files.update(files)
        fingerprints[wheel.name] = checksum(wheel.read_bytes())
    native_wheel = ROOT / ".artifacts/n03-wheels/homelab_mcp-0.25.0-py3-none-any.whl"
    native_files = wheel_files(native_wheel)
    for path in (native / "src/homelab_mcp").rglob("*"):
        if (
            path.is_file()
            and native_files.get(str(path.relative_to(native / "src")))
            != path.read_bytes()
        ):
            raise ValueError("native_wheel_source_mismatch")
    contract = json.loads((native / "contract/PINNED.json").read_text())
    for name, digest in contract["sha256"].items():
        if (
            hashlib.sha256(native_files["homelab_mcp/_vendored/" + name]).hexdigest()
            != digest
        ):
            raise ValueError("native_contract_changed")
    fingerprints[native_wheel.name] = checksum(native_wheel.read_bytes())
    lock = json.loads((native / "vendor/atrium-artifacts.lock.json").read_text())
    for package in ("profiles", "resolver"):
        path = native / "vendor" / f"atrium_{package}-0.1.0-py3-none-any.whl"
        expected = lock["wheels"]["atrium-" + package]["sha256"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError("native_shared_wheel_changed")
        native_files.update(wheel_files(path))
        fingerprints["native/" + path.name] = checksum(path.read_bytes())
    certifi = Path(
        json.loads((ROOT / ".artifacts/n03-certifi-build.json").read_text())[0][
            "outputs"
        ]["out"]
    )
    for path in (certifi / "lib/python3.12/site-packages/certifi").glob("*.py"):
        relative = "certifi/" + path.name
        resolver_files[relative] = native_files[relative] = path.read_bytes()
        fingerprints["nix/" + relative] = checksum(path.read_bytes())
    extra = ROOT / ".artifacts/n03-native-extra"
    expected_extra = pins["native_runtime_extra"]["packages"]
    allowed_extra = tuple(
        prefix
        for name, version in expected_extra.items()
        for prefix in (name + "/", name + "-" + version + ".dist-info/")
    )
    for name, version in expected_extra.items():
        metadata = extra / f"{name}-{version}.dist-info/METADATA"
        if not metadata.is_file():
            raise ValueError("declared_native_runtime_dependency_missing")
        package = BytesParser().parsebytes(metadata.read_bytes())
        if package["Name"].lower() != name or package["Version"] != version:
            raise ValueError("native_runtime_dependency_version_mismatch")
    for path in extra.rglob("*") if extra.exists() else ():
        if path.is_symlink():
            raise ValueError("native_runtime_dependency_symlink")
        if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc":
            relative = str(path.relative_to(extra))
            if not relative.startswith(allowed_extra) or relative in native_files:
                raise ValueError("native_runtime_dependency_overrides_source")
            native_files[relative] = path.read_bytes()
    fixtures = {
        str(path.relative_to(ROOT / "tests/atrium_n03")): path.read_bytes()
        for path in (ROOT / "tests/atrium_n03").iterdir()
        if path.suffix in (".py", ".mjs")
    }
    fixtures["egress.py"] = (ROOT / "tests/atrium_n06/egress.py").read_bytes()
    module_hashes = {
        "resolver": {name: checksum(body) for name, body in resolver_files.items()},
        "native": {name: checksum(body) for name, body in native_files.items()},
        "fixture": {name: checksum(body) for name, body in fixtures.items()},
    }
    return {
        "resolver-python": zip_files(resolver_files),
        "native-python": zip_files(native_files),
        "fixture": zip_files(fixtures),
    }, {
        "inputs": inputs,
        "wheels": fingerprints,
        "native_shared_pin": lock.get("source_revision", lock.get("revision")),
        "native_shared_lock": checksum(
            (native / "vendor/atrium-artifacts.lock.json").read_bytes()
        ),
        "runtime_members": module_hashes,
    }


def source_identity():
    names = subprocess.run(
        [
            "git",
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "--",
            "tests/atrium_n03",
            "tests/atrium_n06/egress.py",
            "tests/atrium_n06/native_runner.py",
            "tests/atrium_n05/supervisor.py",
            "lib/service-uids.nix",
            "lib/host-defaults.nix",
            "flake.nix",
            "flake.lock",
            ".github/workflows/nix-build.yml",
            "docs/services/atrium-foundation.md",
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()
    return {
        name: checksum((ROOT / name).read_bytes())
        for name in sorted(set(names))
        if not name.startswith("tests/atrium_n03/results/") and (ROOT / name).is_file()
    }
