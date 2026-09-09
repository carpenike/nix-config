"""Bundle declared immutable service source and existing Nix runtime tools."""

import hashlib
import json
import subprocess
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / ".artifacts"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def selected_tool_outputs(rows, identities):
    by_derivation = {row["drvPath"]: row for row in rows}
    if len(by_derivation) != len(rows) or set(by_derivation) != set(
        identities.values()
    ):
        raise ValueError("runtime_tool_derivation_set_mismatch")
    return {
        kind: [by_derivation[identities[name]] for name in names]
        for kind, names in (
            ("tools", ("caddy", "socat", "nftables", "iproute2", "privilege")),
            ("node", ("node",)),
            ("certifi", ("certifi",)),
        )
    }


def main():
    build_output = ARTIFACTS / "n03-build-all.json"
    derivations = ARTIFACTS / "n03-tool-derivations.json"
    if build_output.exists() or derivations.exists():
        selected = selected_tool_outputs(
            json.loads(build_output.read_text()), json.loads(derivations.read_text())
        )
        for kind, rows in selected.items():
            (ARTIFACTS / f"n03-{kind}-build.json").write_text(
                json.dumps(rows, indent=2) + "\n"
            )
    inputs = json.loads((ARTIFACTS / "n03-inputs.json").read_text())
    pins = json.loads((ROOT / "tests/atrium_n03/pins.json").read_text())
    whiskey = ARTIFACTS / "source/whiskey"
    for name, record in inputs.items():
        key = {"homelab-mcp": "native", "whiskey-whiskey-whiskey": "consumer"}.get(
            name, name
        )
        if record["rev"] != pins[key]:
            raise ValueError("unaccepted_component")
    for path in Path(inputs["whiskey-whiskey-whiskey"]["path"]).rglob("*"):
        if path.is_file() and path.suffix in (".ts", ".tsx", ".json"):
            copied = whiskey / path.relative_to(
                inputs["whiskey-whiskey-whiskey"]["path"]
            )
            if copied.read_bytes() != path.read_bytes():
                raise ValueError("accepted_whiskey_source_changed")

    outputs = json.loads((ARTIFACTS / "n03-tools-build.json").read_text())
    outputs += json.loads((ARTIFACTS / "n03-node-build.json").read_text())
    roots = sorted(
        {
            value
            for row in outputs
            for name, value in row["outputs"].items()
            if name != "man"
        }
    )
    for binary in ("caddy", "socat", "nft", "ip", "setpriv", "node"):
        if not any((Path(root) / "bin" / binary).is_file() for root in roots):
            raise ValueError("declared_runtime_tool_missing_" + binary)
    closure = json.loads(
        subprocess.run(
            ["nix", "path-info", "--builders", "", "--recursive", "--json", *roots],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    )
    if isinstance(closure, list):
        closure = {row["path"]: row for row in closure}
    tool_archive = ARTIFACTS / "n03-linux-tools.tar.gz"
    with tarfile.open(tool_archive, "w:gz") as archive:
        for path in sorted(closure):
            archive.add(path, arcname=path.lstrip("/"))

    def include(member):
        parts = Path(member.name).parts
        if any(
            part in (".git", ".github", "__pycache__") or part.startswith(".env")
            for part in parts
        ):
            return None
        return None if member.name.endswith((".pyc", ".map")) else member

    whiskey_archive = ARTIFACTS / "n03-whiskey.tar.gz"
    for path in (whiskey / "node_modules").rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(whiskey):
            raise ValueError("external_runtime_dependency_link")
    with tarfile.open(whiskey_archive, "w:gz", dereference=True) as archive:
        for name in ("dist", "node_modules", "package.json"):
            archive.add(whiskey / name, arcname=name, filter=include)
    receipt = {
        "tools": {
            "roots": roots,
            "closure": closure,
            "sha256": digest(tool_archive),
        },
        "whiskey": {
            "revision": pins["consumer"],
            "sha256": digest(whiskey_archive),
            "lock_sha256": digest(whiskey / "package-lock.json"),
            "compiled": {
                str(path.relative_to(whiskey)): digest(path)
                for path in sorted((whiskey / "dist").rglob("*"))
                if path.is_file()
            },
        },
    }
    (ARTIFACTS / "n03-runtime-artifacts.json").write_text(
        json.dumps(receipt, indent=2) + "\n"
    )
    print(
        json.dumps(
            {
                "tool_paths": len(closure),
                "compiled_files": len(receipt["whiskey"]["compiled"]),
            }
        )
    )


if __name__ == "__main__":
    main()
