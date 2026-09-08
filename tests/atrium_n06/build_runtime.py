"""Bundle unmodified compiled Whiskey and its existing production dependencies."""

import argparse
import hashlib
import io
import json
import subprocess
import tarfile
from pathlib import Path

from source_artifact import (
    ARCHIVE_SHA256,
    REVISION,
    immutable_source,
    materialize,
    sha256,
    source_hashes,
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--whiskey", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    files = immutable_source(args.whiskey)
    root = materialize(files, output.parent / "whiskey-source")
    compiler = root / "node_modules/typescript/bin/tsc"
    if not compiler.is_file():
        raise RuntimeError("existing_runtime_dependency_missing")
    subprocess.run(
        [
            "node",
            str(compiler),
            "-p",
            str(root / "tsconfig.server.json"),
            "--outDir",
            str(output / "server"),
            "--incremental",
            "false",
        ],
        check=True,
    )
    packages = {}

    def dependency(name, start):
        directory = start
        while not (directory / "node_modules" / name / "package.json").is_file():
            if directory == directory.parent:
                raise RuntimeError("existing_runtime_dependency_missing")
            directory = directory.parent
        package = directory / "node_modules" / name
        if package in packages:
            return
        manifest = json.loads((package / "package.json").read_text())
        packages[package] = {
            "name": manifest["name"],
            "version": manifest["version"],
            "source": str(package.resolve()),
            "path": str(package.relative_to(root)),
        }
        for child in manifest.get("dependencies", {}):
            dependency(child, package)

    manifest = json.loads((root / "package.json").read_text())
    for name in manifest["dependencies"]:
        dependency(name, root)

    def public(member):
        if any(
            part in ("test", "tests", "examples", ".git", ".github", "__pycache__")
            or part.startswith(".env")
            for part in Path(member.name).parts
        ):
            return None
        return None if member.name.endswith((".pyc", ".map")) else member

    archive = output / "whiskey.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(output / "server", arcname="server", filter=public)
        for package, description in sorted(packages.items()):
            bundle.add(package.resolve(), arcname=description["path"], filter=public)
        body = b'{"type":"module"}\n'
        member = tarfile.TarInfo("package.json")
        member.size = len(body)
        bundle.addfile(member, io.BytesIO(body))
    receipt = {
        "source_revision": REVISION,
        "source_archive_sha256": ARCHIVE_SHA256,
        "source_sha256": source_hashes(files),
        "packages": list(packages.values()),
        "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "compiled": {
            str(path.relative_to(output)): {
                "algorithm": "sha256",
                "digest": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
            for path in sorted((output / "server").rglob("*.js"))
        },
    }
    with tarfile.open(archive) as bundle:
        receipt["members_sha256"] = {
            member.name: sha256(bundle.extractfile(member).read())
            for member in bundle.getmembers()
            if member.isfile()
        }
    for name, body in files.items():
        if (root / name).read_bytes() != body:
            raise RuntimeError("whiskey_source_changed_during_build")
    (output / "build.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(
        json.dumps({"packages": len(packages), "archive_bytes": archive.stat().st_size})
    )


if __name__ == "__main__":
    main()
