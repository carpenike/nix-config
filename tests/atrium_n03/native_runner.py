"""N03 exact-resource runner; native code, Caddy and kernel boundaries are not substitutes."""

import argparse
import base64
import hashlib
import json
import secrets
import subprocess
import sys
import traceback
from pathlib import Path

from artifacts import ROOT, checksum, source_identity, verified_payloads


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--imports-only", action="store_true")
    parser.add_argument("--bootstrap-only", action="store_true")
    parser.add_argument("--fault-probe", action="store_true")
    args = parser.parse_args()
    inputs = json.loads((ROOT / ".artifacts/n03-inputs.json").read_text())
    sys.path.insert(0, inputs["atrium"]["path"])
    from harness.common import EvidenceWriter, PINS, require
    from harness.containers import Resources

    sys.path.insert(0, str(ROOT / "tests/atrium_n06"))
    from native_runner import Process as LegacyProcess

    payloads, identity = verified_payloads()
    fixture = json.loads(
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
                f'let f = builtins.getFlake "{ROOT}"; in import {ROOT}/tests/atrium_n03/fixture.nix {{ inherit (f) inputs; }}',
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    )
    caddy = subprocess.run(
        [
            "nix",
            "eval",
            "--builders",
            "",
            "--no-write-lock-file",
            "--impure",
            "--raw",
            "--expr",
            f'let f = builtins.getFlake "{ROOT}"; in import {ROOT}/tests/atrium_n03/caddy.nix {{ fixture = import {ROOT}/tests/atrium_n03/fixture.nix {{ inherit (f) inputs; }}; }}',
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    runtime = json.loads((ROOT / ".artifacts/n03-runtime-artifacts.json").read_text())
    pins = json.loads((ROOT / "tests/atrium_n03/pins.json").read_text())
    for filename, expected in (
        ("n03-linux-tools.tar.gz", runtime["tools"]["sha256"]),
        ("n03-whiskey.tar.gz", runtime["whiskey"]["sha256"]),
        ("n03-sqlite-addon.tar.gz", pins["sqlite_addon"]["sha256"]),
    ):
        require(
            hashlib.sha256((ROOT / ".artifacts" / filename).read_bytes()).hexdigest()
            == expected,
            "runtime_artifact_changed",
        )
    runtime["whiskey"]["compiled"] = {
        name: {"algorithm": "sha256", "digest": value}
        for name, value in runtime["whiskey"]["compiled"].items()
    }
    tools = {
        name: next(
            str(Path(root) / "bin" / binary)
            for root in runtime["tools"]["roots"]
            if (Path(root) / "bin" / binary).is_file()
        )
        for name, binary in (
            ("caddy", "caddy"),
            ("socat", "socat"),
            ("nft", "nft"),
            ("ip", "ip"),
            ("setpriv", "setpriv"),
            ("node", "node"),
        )
    }
    require(
        args.evidence.resolve().is_relative_to(ROOT / "tests/atrium_n03/results")
        and not args.evidence.exists(),
        "new_n03_receipt_required",
    )
    result = {
        "ticket": "ATR-N03",
        "run_id": "n03-" + secrets.token_hex(8),
        "status": "bootstrap",
        "full_n03": "incomplete",
        "c8_adopted": True,
        "source": {
            "commit": subprocess.run(
                ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True
            ).stdout.strip(),
            "dirty": bool(
                subprocess.run(
                    ["git", "status", "--porcelain"],
                    capture_output=True,
                    text=True,
                    check=True,
                ).stdout.strip()
            ),
            "owner_spec_sha256": hashlib.sha256(args.spec.read_bytes()).hexdigest(),
            "files": source_identity(),
            "public_configuration": checksum(
                json.dumps(fixture, sort_keys=True).encode()
            ),
            "caddy_configuration": checksum(caddy.encode()),
            "compiled_runtime": runtime,
            **identity,
        },
        "scope": {
            "actual_native_paths": [
                "Caddy",
                "R01/R02/R03/R04/R05/R07/R08",
                "M01/M02/M03/M04/C8",
                "W01/W02",
                "S01",
            ],
            "model_plane": "blocked: protected non-secret publication sharing is not implemented",
            "native_jti_deny": "accepted R07 native-JTI classifier; real R05 permit/deny/recovery required in this run",
            "retained_native_policy": "accepted private C8 transport wired; actual native OAuth/current-policy pairs required in this run",
            "full_phase1": False,
            "browser_local_network_permission": "not executed",
            "whiskey_egress_granularity": "IPv4 destination address and TCP port, not hostname/modality",
        },
    }
    writer = EvidenceWriter(args.evidence, result)
    resources = Resources(result["run_id"], result, writer.publish)
    resources.select_local_engine()
    before = resources.command(
        ["ps", "--all", "--format", "{{.ID}}|{{.Names}}|{{.State}}"]
    )
    result["foreign_before"] = before.splitlines()
    require(
        not any(
            line.split("|")[2] == "running" and line.split("|")[1] != "ambit-db"
            for line in before.splitlines()
        ),
        "shared_native_vm_busy",
    )
    try:
        arch = json.loads(resources.command(["info", "--format", "json"]))["host"][
            "arch"
        ]
        image = resources.image(PINS["litellm"]["image"], "linux/" + arch)
        result["image"] = image
        options = [
            "--tmpfs",
            "/run/atrium-n03:rw,nosuid,nodev,size=512m,mode=0755",
            "--tmpfs",
            "/var/lib:rw,nosuid,nodev,size=256m,mode=0755",
            "--tmpfs",
            "/run/credentials:rw,nosuid,nodev,size=32m,mode=0755",
        ]
        if not args.imports_only:
            resources.create_network()
            options.extend(["--cap-add", "NET_ADMIN"])
            for name in fixture["names"].values():
                target = (
                    "127.0.0.1"
                    if name == fixture["names"]["native"]
                    else fixture["frontAddress"]
                )
                options.extend(["--add-host", name + ":" + target])
        identifier = resources.create(
            "foundation",
            image["image_id"],
            "python",
            ["-B", "-c", (ROOT / "tests/atrium_n03/runtime.py").read_text()],
            memory="3072m",
            network=not args.imports_only,
            options=tuple(options),
        )
        resources.command(
            [
                "cp",
                str(ROOT / ".artifacts/n03-linux-tools.tar.gz"),
                identifier + ":/opt/n03-tools.tar.gz",
            ],
            timeout=120,
        )
        if not args.imports_only:
            for payload in ("whiskey", "sqlite"):
                destination = "n03-" + payload + ".tar.gz"
                name = "n03-sqlite-addon.tar.gz" if payload == "sqlite" else destination
                resources.command(
                    [
                        "cp",
                        str(ROOT / ".artifacts" / name),
                        identifier + ":/opt/" + destination,
                    ],
                    timeout=120,
                )
        process = LegacyProcess(
            resources,
            identifier,
            {
                "archives": {
                    name: base64.b64encode(value).decode()
                    for name, value in payloads.items()
                },
                **(
                    {}
                    if args.imports_only
                    else {"fixture": fixture, "caddy": caddy, "tools": tools}
                ),
            },
        )
        boot = process.receive()
        result["bootstrap"] = {
            key: value for key, value in boot.items() if key != "public"
        }
        if boot.get("ready") and not args.imports_only:
            require(
                all(
                    state.get("NoNewPrivs") == "1"
                    and all(
                        int(value, 16) == 0
                        for name, value in state.items()
                        if name.startswith("Cap")
                    )
                    and int(state["Uid"].split()[1]) != 0
                    for state in boot["services"].values()
                ),
                "application_retained_privileges",
            )
        if boot.get("ready") and args.fault_probe:
            result["fault_probe"] = process.call("feed-outage", enabled=True)
            require(result["fault_probe"].get("changed"), "owned_fault_probe_failed")
            process.call("feed-outage", enabled=False)
        if boot.get("ready") and not args.imports_only and not args.bootstrap_only:
            networks = json.loads(
                resources.command(
                    [
                        "inspect",
                        "--format",
                        "{{json .NetworkSettings.Networks}}",
                        identifier,
                    ]
                )
            )
            foundation_address = networks[resources.network]["IPAddress"]
            options = [
                "--cap-add",
                "NET_ADMIN",
                "--tmpfs",
                "/run/atrium-n03-client:rw,nosuid,nodev,size=128m,mode=0700",
            ]
            for name in fixture["names"].values():
                options.extend(["--add-host", name + ":" + fixture["frontAddress"]])
            source = (ROOT / "tests/atrium_n03/client.py").read_text()
            client_id = resources.create(
                "untrusted-client",
                image["image_id"],
                "python",
                ["-B", "-c", source],
                memory="512m",
                options=tuple(options),
            )
            resources.command(
                [
                    "cp",
                    str(ROOT / ".artifacts/n03-linux-tools.tar.gz"),
                    client_id + ":/opt/n03-tools.tar.gz",
                ],
                timeout=120,
            )
            client = LegacyProcess(
                resources,
                client_id,
                {
                    "tools": tools,
                    "public": boot["public"],
                    "source": source,
                    "python": base64.b64encode(payloads["resolver-python"]).decode(),
                    "fixture": fixture,
                    "foundationAddress": foundation_address,
                    "frontAddress": fixture["frontAddress"],
                    "uid": fixture["ids"]["atrium-client-fixture"]["uid"],
                },
            )
            observed = client.receive()
            result["client"] = observed
            require(
                observed.get("ready") and observed["namespace"] != boot["namespace"],
                "client_namespace_not_separate",
            )
            require(
                all(
                    int(value, 16) == 0
                    for name, value in observed["privileges"].items()
                    if name.startswith("Cap")
                ),
                "client_retained_capability",
            )
            require(
                observed["privileges"]["NoNewPrivs"] == "1", "client_can_gain_privilege"
            )
            result["cases"] = []
            from cases import execute

            try:
                execute(
                    fixture,
                    process,
                    client,
                    foundation_address,
                    result["cases"],
                    writer.publish,
                )
                result["status"] = "partial"
            except (AssertionError, KeyError, RuntimeError) as error:
                result["status"] = "failed"
                result["failure"] = (
                    str(error)
                    if isinstance(error, AssertionError) and str(error)
                    else type(error).__name__
                )
                location = traceback.extract_tb(error.__traceback__)[-1]
                result["failure_location"] = {
                    "file": Path(location.filename).name,
                    "line": location.lineno,
                }
            finally:
                client.close()
        else:
            result["status"] = "bootstrap-passed" if boot.get("ready") else "blocked"
        if boot.get("ready"):
            process.close()
    finally:
        resources.cleanup()
        after = resources.command(
            ["ps", "--all", "--format", "{{.ID}}|{{.Names}}|{{.State}}"]
        )
        result["foreign_after"] = after.splitlines()
        result["foreign_resources_unchanged"] = before == after
        result["source_unchanged"] = (
            source_identity() == result["source"]["files"]
            and hashlib.sha256(args.spec.read_bytes()).hexdigest()
            == result["source"]["owner_spec_sha256"]
            and subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
            == result["source"]["commit"]
        )
        writer.publish()
        require(result["foreign_resources_unchanged"], "foreign_resource_changed")
        require(result["source_unchanged"], "source_changed_during_native_run")
    print(
        json.dumps(
            {
                "status": result["status"],
                "bootstrap": result.get("bootstrap"),
                "cases": result.get("cases"),
                "fault_probe": result.get("fault_probe"),
                "failure": result.get("failure"),
                "failure_location": result.get("failure_location"),
                "cleanup": result.get("cleanup"),
            }
        )
    )
    return 0 if result["status"] in ("passed", "bootstrap-passed") else 2


if __name__ == "__main__":
    raise SystemExit(main())
