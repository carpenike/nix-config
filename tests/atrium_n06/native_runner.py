"""Actual W03/N04/native gateway under invocation-owned N06 namespace enforcement."""

import argparse
import base64
import hashlib
import importlib
import json
import logging
import secrets
import select
import subprocess
import sys
import tarfile
from collections import Counter
from pathlib import Path

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from source_artifact import (
    ARCHIVE_SHA256,
    REVISION,
    immutable_source,
    verify_runtime,
)

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tests/atrium_n05"))
supervisor = importlib.import_module("supervisor")
git, inventory, load_harness = (
    supervisor.git,
    supervisor.inventory,
    supervisor.load_harness,
)

MEDIA = "198.20.0.10"
CANARY = "203.0.113.77"
SQLITE_DIGEST = "2a76bef5586c21c1ba9e4f21c7a0adf4727cae061a1ed7b8872f5aec9fd191ff"
RUNTIME = "/run/atrium-n06"


class Process:
    def __init__(self, resources, identifier, payload):
        self.process = subprocess.Popen(
            [
                *resources.prefix_command,
                "start",
                "--attach",
                "--interactive",
                identifier,
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        resources.processes.append(self.process)
        resources.process_records.append(
            {"status": "attached", "stdin": "not recorded; runtime inputs"}
        )
        self.send(payload)

    def send(self, value):
        self.process.stdin.write(json.dumps(value) + "\n")
        self.process.stdin.flush()

    def receive(self, seconds=90):
        if not select.select([self.process.stdout], [], [], seconds)[0]:
            raise RuntimeError("n06_fixture_response_timeout")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("n06_fixture_exited")
        return json.loads(line)

    def call(self, action, **fields):
        self.send({"action": action, **fields})
        return self.receive()

    def close(self):
        if self.process.poll() is None:
            self.send({"action": "stop"})
            self.process.stdin.close()
            self.process.wait(timeout=15)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--whiskey", type=Path, required=True)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    native, harness_hashes = load_harness(args.harness)
    from harness.common import EvidenceWriter, require
    from harness.containers import Resources

    require(
        args.evidence.resolve().is_relative_to(HERE / "results")
        and not args.evidence.exists(),
        "new_n06_evidence_path_required",
    )
    archived_whiskey = immutable_source(args.whiskey)
    whiskey_files = (
        "server/lib/anthropic.ts",
        "server/lib/atrium-model.ts",
        "server/lib/image-gen.ts",
        "server/lib/safe-fetch.ts",
        "server/lib/oidc.ts",
        "server/integrations/partiful-firebase.ts",
        "server/lib/plex.ts",
        "server/lib/partiful.ts",
        "server/lib/resource-server.ts",
        "server/lib/pocketid-admin.ts",
        "server/lib/cooklang.ts",
        "server/lib/mailer.ts",
        "server/lib/web-push.ts",
        "package.json",
        "package-lock.json",
        "scripts/atrium-w03/provider.py",
    )
    compiled_runtime = verify_runtime(
        ROOT / ".artifacts/n06-whiskey-runtime", archived_whiskey
    )
    tools = json.loads((ROOT / ".artifacts/n06-linux-tools.json").read_text())
    tool_archive = ROOT / ".artifacts/n06-linux-tools.tar.gz"
    consumer_archive = ROOT / ".artifacts/n06-whiskey-runtime/whiskey.tar.gz"
    addon = (
        ROOT
        / ".artifacts/n06-native-addon/better-sqlite3-v12.10.0-node-v147-linux-arm64.tar.gz"
    )
    require(
        hashlib.sha256(tool_archive.read_bytes()).hexdigest() == tools["sha256"],
        "linux_tool_archive_changed",
    )
    require(
        hashlib.sha256(addon.read_bytes()).hexdigest() == SQLITE_DIGEST,
        "native_addon_digest_mismatch",
    )
    generated = json.loads(
        subprocess.run(
            [
                "nix",
                "eval",
                "--builders",
                "",
                "--offline",
                "--no-write-lock-file",
                "--impure",
                "--json",
                "--expr",
                f"let flake = builtins.getFlake {json.dumps(str(ROOT))}; in import {HERE / 'fixture.nix'} {{ atrium = flake.inputs.atrium; }}",
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=120,
        ).stdout
    )
    module_checks = json.loads(
        subprocess.run(
            [
                "nix",
                "eval",
                "--builders",
                "",
                "--offline",
                "--no-write-lock-file",
                "--impure",
                "--json",
                "--expr",
                f"let f = builtins.getFlake {json.dumps(str(ROOT))}; in import {HERE / 'evaluate.nix'} {{ inherit (f.inputs) nixpkgs atrium; }}",
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=120,
        ).stdout
    )
    require(
        all(value is True for value in module_checks.values()),
        "n06_module_assertion_failed",
    )
    result = {
        "ticket": "ATR-N06",
        "run_id": "n06-" + secrets.token_hex(8),
        "status": "running",
        "full_n06": "incomplete",
        "module_checks": module_checks,
        "source": {
            "commit": git(ROOT, "rev-parse", "HEAD").decode().strip(),
            "dirty": bool(git(ROOT, "status", "--porcelain").strip()),
            "consumer_commit": REVISION,
            "consumer_implementation": REVISION,
            "consumer_archive_sha256": ARCHIVE_SHA256,
            "whiskey_files": {
                name: {
                    "algorithm": "sha256",
                    "digest": hashlib.sha256(archived_whiskey[name]).hexdigest(),
                }
                for name in whiskey_files
            },
            "owner_spec_sha256": hashlib.sha256(args.spec.read_bytes()).hexdigest(),
            "atrium_revision": json.loads((ROOT / "flake.lock").read_text())["nodes"][
                "atrium"
            ]["locked"]["rev"],
            "nixpkgs_revision": json.loads((ROOT / "flake.lock").read_text())["nodes"][
                "nixpkgs"
            ]["locked"]["rev"],
            "harness": harness_hashes,
            "compiled_runtime": compiled_runtime,
            "linux_tools": tools,
            "sqlite_addon_sha256": SQLITE_DIGEST,
            "registry_sha256": hashlib.sha256(
                json.dumps(generated, sort_keys=True).encode()
            ).hexdigest(),
            "files": {
                str(path.relative_to(ROOT)): {
                    "algorithm": "sha256",
                    "digest": hashlib.sha256(path.read_bytes()).hexdigest(),
                }
                for folder in (HERE, ROOT / "pkgs/atrium-litellm-controller")
                for path in sorted(folder.rglob("*"))
                if path.is_file() and path.suffix in (".py", ".mjs", ".nix")
            },
        },
    }
    if args.prepare_only:
        result.update(
            status="prepared", native_execution=False, bounded_n06_gate="unexecuted"
        )
        EvidenceWriter(args.evidence, result)
        print(
            json.dumps(
                {
                    "ticket": "ATR-N06",
                    "status": "prepared",
                    "native_execution": False,
                    "evidence": str(args.evidence),
                }
            )
        )
        return 0
    require(not result["source"]["dirty"], "clean_n06_source_required")
    writer = EvidenceWriter(args.evidence, result)
    state = {}
    credentials = {
        name: secrets.token_urlsafe(32)
        for name in (
            "openai",
            "gemini",
            "openrouter",
            "partiful-refresh",
            "partiful-api",
            "plex",
            "calendar",
            "pocketid-admin",
            "signup-token",
            "mailgun",
        )
    }
    vapid = ec.generate_private_key(ec.SECP256R1())
    credentials["vapid-public"] = (
        base64.urlsafe_b64encode(
            vapid.public_key().public_bytes(
                serialization.Encoding.X962,
                serialization.PublicFormat.UncompressedPoint,
            )
        )
        .decode()
        .rstrip("=")
    )
    credentials["vapid-private"] = (
        base64.urlsafe_b64encode(
            vapid.private_numbers().private_value.to_bytes(32, "big")
        )
        .decode()
        .rstrip("=")
    )
    with tarfile.open(consumer_archive) as archive:
        wire_library = {
            member.name.removeprefix("node_modules/http_ece/"): archive.extractfile(
                member
            )
            .read()
            .decode()
            for member in archive.getmembers()
            if member.isfile()
            and member.name.startswith("node_modules/http_ece/")
            and Path(member.name).suffix in (".js", ".json")
        }
    upstream_observer = secrets.token_urlsafe(32)
    ip_tool = tools["roots"][1] + "/bin/ip"
    nft_tool = tools["roots"][0] + "/bin/nft"
    privilege_tool = tools["roots"][2] + "/bin/setpriv"

    class OwnedResources(Resources):
        def select_local_engine(self):
            super().select_local_engine()
            state["before"] = inventory(self)
            self.result["foreign_before"] = state["before"]
            require(
                not any(
                    row["state"] == "running" and row["name"] != "ambit-db"
                    for row in state["before"].values()
                ),
                "shared_native_vm_busy",
            )

        def create(self, role, image, entrypoint, arguments, **options):
            if role in ("provider", "family-provider"):
                arguments = [
                    "-B",
                    "-c",
                    archived_whiskey["scripts/atrium-w03/provider.py"].decode(),
                ]
            return super().create(role, image, entrypoint, arguments, **options)

        def cleanup(self):
            super().cleanup()
            after = inventory(self)
            self.result["foreign_after"] = {
                key: after.get(key) for key in state.get("before", {})
            }
            self.result["foreign_resources_unchanged"] = self.result[
                "foreign_after"
            ] == state.get("before", {})
            require(
                self.result["foreign_resources_unchanged"], "foreign_resource_changed"
            )
            self.publish()

    def address(resources, identifier):
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
        return networks[resources.network]["IPAddress"]

    def configure(provider):
        config = native.configuration(provider)
        config["general_settings"]["store_model_in_db"] = True
        config["router_settings"].update(max_fallbacks=0, model_group_alias={})
        return config

    def prepare(resources, provider_name, provider_key):
        state["resources"] = resources
        state["provider_keys"] = {
            "personal-model": provider_key.get_secret_value(),
            "family-model": secrets.token_urlsafe(32),
        }
        family = resources.create(
            "family-provider",
            resources.result["images"]["litellm"]["image_id"],
            "python",
            ["-B", "-c", ""],
            memory="256m",
            port=8000,
            options=("--network-alias", "family.models.atrium.invalid"),
        )
        state["family_observer"] = secrets.token_urlsafe(32)
        resources.start(
            family,
            json.dumps(
                {
                    "inference": state["provider_keys"]["family-model"],
                    "observer": state["family_observer"],
                }
            ),
        )
        resources.wait_running(family)
        state["family_endpoint"] = resources.endpoint(family, 8000)
        hosts = sorted(
            {
                host
                for destination in generated["egress"]["destinations"].values()
                for host in destination["hosts"]
            }
            | {
                "api.anthropic.com",
                "cohost-undeclared.atrium.invalid",
                "whiskey.atrium.invalid",
            }
        )
        upstreams = resources.create(
            "upstreams",
            resources.result["images"]["litellm"]["image_id"],
            "python",
            ["-B", "-c", (HERE / "upstreams.py").read_text()],
            memory="768m",
            port=8000,
            options=(
                "--cap-add",
                "NET_ADMIN",
                "--tmpfs",
                "/run/atrium-n06-upstreams:rw,nosuid,nodev,size=16m,mode=0700",
            ),
        )
        resources.command(
            ["cp", str(tool_archive), upstreams + ":/opt/n06-tools.tar.gz"], timeout=120
        )
        resources.start(
            upstreams,
            json.dumps(
                {
                    "hosts": hosts,
                    "credentials": credentials,
                    "observer": upstream_observer,
                    "gateway": "http://" + resources.prefix + "-litellm:4000",
                    "media_address": MEDIA,
                    "canary_address": CANARY,
                    "ip": ip_tool,
                    "feature_source": (HERE / "required_features.py").read_text(),
                    "push_wire": (HERE / "push_wire.mjs").read_text(),
                    "wire_library": wire_library,
                }
            ),
        )
        resources.wait_running(upstreams)
        endpoint = resources.endpoint(upstreams, 8000)
        with httpx.Client(base_url=endpoint, trust_env=False, timeout=10) as client:
            headers = {"Authorization": "Bearer " + upstream_observer}
            native.wait_http(client, "/state", headers, seconds=45)
            state["ca"] = client.get("/ca", headers=headers).text
            state["feature_inputs"] = client.get("/bootstrap", headers=headers).json()
        state.update(
            upstreams=upstreams,
            observer_endpoint=endpoint,
            upstream_address=address(resources, upstreams),
            hosts=hosts,
        )

    def exercise(
        client, observer, control, observer_headers, evidence, invocation, checkpoint
    ):
        resources = state["resources"]
        runtime_loader = """
import json,pathlib,sys,traceback
try:
 exec(compile(SOURCE,"runtime.py","exec"))
except Exception as error:  # noqa: BLE001 - redacted fixture boundary
 frame=traceback.extract_tb(error.__traceback__)[-1]
 print(json.dumps({"ready":False,"code":getattr(error,"code",type(error).__name__),"file":pathlib.Path(frame.filename).name,"line":frame.lineno}),flush=True)
"""
        runtime_loader = runtime_loader.replace(
            "SOURCE", repr((HERE / "runtime.py").read_text())
        )
        options = [
            "--cap-add",
            "NET_ADMIN",
            "--tmpfs",
            RUNTIME + ":rw,nosuid,nodev,size=256m,mode=0755",
        ]
        for host in state["hosts"]:
            ip = (
                MEDIA
                if host == "media.atrium.invalid"
                else CANARY
                if host == "api.anthropic.com"
                else state["upstream_address"]
            )
            options.extend(["--add-host", host + ":" + ip])
        child = resources.create(
            "whiskey",
            evidence["images"]["litellm"]["image_id"],
            "python",
            ["-B", "-c", runtime_loader],
            memory="1536m",
            options=tuple(options),
        )
        for path, name in (
            (tool_archive, "n06-tools.tar.gz"),
            (consumer_archive, "whiskey.tar.gz"),
            (addon, "sqlite.tar.gz"),
        ):
            resources.command(["cp", str(path), child + ":/opt/" + name], timeout=120)
        sources = {
            "atrium_litellm/" + path.name: path.read_text()
            for path in (ROOT / "pkgs/atrium-litellm-controller/atrium_litellm").glob(
                "*.py"
            )
        }
        sources["egress.py"] = (HERE / "egress.py").read_text()
        process = Process(
            resources,
            child,
            {
                "sources": sources,
                "desired": generated["litellm"],
                "policy": generated["egress"],
                "bindings": {
                    name: [MEDIA if name == "media" else state["upstream_address"]]
                    for name in generated["egress"]["destinations"]
                },
                "installation": invocation,
                "gateway": "http://" + resources.prefix + "-litellm:4000",
                "management_key": control["Authorization"].removeprefix("Bearer "),
                "provider_keys": state["provider_keys"],
                "credentials": credentials,
                "ca": state["ca"],
                "consumer": (HERE / "consumer.mjs").read_text(),
                "feature_consumer": (HERE / "feature_consumer.mjs").read_text(),
                "feature_inputs": state["feature_inputs"],
                "media_address": MEDIA,
                "canary_address": CANARY,
                "upstream_address": state["upstream_address"],
                "ip": ip_tool,
                "nft": nft_tool,
                "setpriv": privilege_tool,
            },
        )
        boot = process.receive()
        evidence["runtime_boot"] = boot
        checkpoint()
        require(boot.get("ready"), "n06_runtime_not_ready")
        require(
            boot["consumer"]["uid"] == 11001
            and int(boot["consumer"]["capabilities"], 16) == 0
            and set(boot["consumer"]["capability_sets"])
            == {"CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"}
            and all(
                int(value, 16) == 0
                for value in boot["consumer"]["capability_sets"].values()
            )
            and boot["consumer"]["no_new_privileges"] == "1",
            "consumer_can_change_egress",
        )
        require(
            not boot["consumer"]["direct_anthropic_present"],
            "undeclared_provider_credential_present",
        )
        evidence["scope"].update(
            {
                "native_only": False,
                "owned_controller": True,
                "protocols": ["POST /v1/messages via actual adopted W03 helper"],
                "network_claim": "Actual nftables UID/address/port enforcement in an invocation-owned namespace; not global N03 topology proof.",
                "actual_helper": "immutable compiled W03 text/image and required native non-model clients",
                "egress": "UID-scoped nftables in exact invocation-owned network namespace",
                "granularity": "IPv4 destination address + TCP port; not hostname or image-only enforcement",
                "registry": "N04 isolated registry with N06 isolated overlays; one generated policy",
                "provider_exceptions": "OpenAI/Gemini/OpenRouter remain direct",
                "production_reference_policy": "separate adoption policy; bounded synthetic destinations explicitly configured here",
                "required_nonmodel_scope": "actual helper/client and native wire validation, not full browser/identity workflows",
                "admission_hook": False,
            }
        )
        headers = {"Authorization": "Bearer " + upstream_observer}
        with httpx.Client(
            base_url=state["observer_endpoint"], trust_env=False, timeout=10
        ) as upstream:

            def counts():
                return upstream.get("/state", headers=headers).json()["events"]

            def case(name, operation):
                row = {"id": name, "status": "running"}
                evidence["cases"].append(row)
                try:
                    operation(row)
                    row["status"] = "passed"
                except Exception as error:  # noqa: BLE001 - redacted fixture result boundary
                    row.update(
                        status="blocked",
                        error=getattr(
                            error,
                            "code",
                            str(error)
                            if isinstance(error, RuntimeError)
                            else type(error).__name__,
                        ),
                    )
                checkpoint()

            try:

                def cannot_remove_filter(row):
                    row["deny"] = process.call("attempt-filter-removal")
                    require(
                        row["deny"].get("attempted") is True
                        and row["deny"].get("exit_code") not in (None, 0)
                        and row["deny"].get("error_code") is None,
                        "consumer_can_remove_filter",
                    )
                    row["table_retained"] = any(
                        entry.get("table", {}).get("name") == "atrium_whiskey"
                        for entry in process.call("rules")["rules"]["nftables"]
                    )
                    require(row["table_retained"], "consumer_removed_filter")

                case("N06-consumer-cannot-remove-filter", cannot_remove_filter)
                rotation = process.call("rotate")
                evidence["initial_controller"] = rotation
                require(rotation.get("ok"), "n04_publication_failed")

                def text(row):
                    start = len(counts())
                    before_model = observer.get(
                        "/_fixture/counts", headers=observer_headers
                    ).json()
                    row["permit"] = process.call("text")
                    row["destinations"] = counts()[start:]
                    after_model = observer.get(
                        "/_fixture/counts", headers=observer_headers
                    ).json()
                    row["native_provider"] = {
                        "requests": after_model["received"] - before_model["received"],
                        "models": after_model["models"][len(before_model["models"]) :],
                        "paths": after_model["paths"][len(before_model["paths"]) :],
                        "credential_matches": after_model["credential_matches"][
                            len(before_model["credential_matches"]) :
                        ],
                    }
                    family_counts = httpx.get(
                        state["family_endpoint"] + "/_fixture/counts",
                        headers={"Authorization": "Bearer " + state["family_observer"]},
                        trust_env=False,
                        timeout=10,
                    ).json()
                    row["foreign_provider_requests"] = family_counts["received"]
                    require(
                        row["native_provider"]
                        == {
                            "requests": 1,
                            "models": ["fixture-personal"],
                            "paths": ["/v1/responses"],
                            "credential_matches": [True],
                        }
                        and row["foreign_provider_requests"] == 0,
                        "wrong_native_model_account",
                    )
                    require(
                        row["permit"].get("status") == 200
                        and row["permit"].get("text") == "fixture-ok",
                        "adopted_text_not_permitted",
                    )
                    require(
                        any(
                            event["host"] == "litellm.atrium.invalid"
                            and event["path"] == "/v1/messages"
                            for event in row["destinations"]
                        ),
                        "wrong_text_destination",
                    )
                    process.call("hide-key")
                    try:
                        start = len(counts())
                        row["deny"] = process.call("text")
                        require(
                            row["deny"].get("status") == 503 and len(counts()) == start,
                            "missing_key_fell_back",
                        )
                    finally:
                        process.call("restore-key")
                    row["recovery"] = process.call("text")
                    require(
                        row["recovery"].get("status") == 200, "text_recovery_failed"
                    )

                case("T16-adopted-text-runtime-credential", text)
                case(
                    "T22-foreign-alias",
                    lambda row: (
                        row.update(deny=process.call("reject-foreign-backend")),
                        require(
                            row["deny"].get("code") == "foreign_alias_backend",
                            "foreign_alias_not_refused",
                        ),
                    ),
                )

                def blocked(row, url):
                    row["reachable_from_setup_uid"] = process.call(
                        "root-probe", url=url
                    )
                    require(
                        row["reachable_from_setup_uid"].get("status") == 200,
                        "deny_target_not_live",
                    )
                    start = len(counts())

                    def rejected_packets():
                        rules = process.call("rules")["rules"]["nftables"]
                        return sum(
                            expression["counter"]["packets"]
                            for entry in rules
                            if "rule" in entry
                            and any("reject" in part for part in entry["rule"]["expr"])
                            for expression in entry["rule"]["expr"]
                            if "counter" in expression
                        )

                    before_reject = rejected_packets()
                    row["deny"] = process.call("fetch", url=url)
                    row["kernel_rejected_packets"] = rejected_packets() - before_reject
                    require(
                        row["deny"].get("ok") is False
                        and len(counts()) == start
                        and row["kernel_rejected_packets"] > 0,
                        "namespace_egress_not_denied",
                    )

                case(
                    "T16-undeclared-direct-provider",
                    lambda row: blocked(row, "https://api.anthropic.com/v1/messages"),
                )
                gateway = next(
                    row["id"]
                    for row in evidence["resources"]
                    if row["role"] == "litellm"
                )
                native_address = address(resources, gateway)
                case(
                    "T4-direct-native-backend",
                    lambda row: blocked(
                        row, "http://" + native_address + ":4000/health/liveliness"
                    ),
                )
                for provider in ("openai", "gemini", "openrouter"):

                    def image(row, provider=provider):
                        start = len(counts())
                        row["permit"] = process.call("image", provider=provider)
                        row["destinations"] = counts()[start:]
                        require(
                            row["permit"].get("ok")
                            and row["permit"]["width"] == row["permit"]["height"] == 2,
                            "native_image_provider_not_permitted",
                        )
                        require(
                            row["destinations"]
                            and all(
                                event["authorized"] for event in row["destinations"]
                            ),
                            "wrong_image_credential",
                        )

                    case("T16-image-" + provider, image)
                for action in ("identity", "partiful", "plex"):
                    case(
                        "T16-non-model-" + action,
                        lambda row, action=action: (
                            row.update(permit=process.call(action)),
                            require(row["permit"].get("ok"), "non_model_not_permitted"),
                        ),
                    )

                def feature_pair(
                    row, action, expected_effects, required_fields, denials
                ):
                    start = len(counts())
                    row["permit"] = process.call(action)
                    row["permit_destinations"] = counts()[start:]
                    require(
                        row["permit"].get("ok") is True
                        and all(
                            row["permit"].get(field) is True
                            for field in required_fields
                        )
                        and row["permit"]["pid"] == boot["consumer"]["pid"]
                        and row["permit"]["uid"] == 11001,
                        "required_native_feature_not_permitted",
                    )
                    effects = [
                        event.get("effect") for event in row["permit_destinations"]
                    ]
                    require(
                        all(effect in effects for effect in expected_effects),
                        "required_native_feature_effect_missing",
                    )
                    row["permit_effect_counts"] = dict(
                        Counter(effect for effect in effects if effect)
                    )
                    limits = {
                        "calendar-sync": {"calendar-read": (1, 1)},
                        "firestore-guests": {
                            "firestore-guest-page": (2, 2),
                            "firestore-event-read": (1, 1),
                        },
                        "firestore-schedule": {"firestore-schedule-write": (1, 1)},
                        "partiful-upload": {"partiful-image-upload": (1, 1)},
                        "external-issuer": {"issuer-jwks": (1, 1)},
                        "pocketid-admin": {
                            "admin-signup-mint": (1, 1),
                            "admin-signup-delete": (1, 1),
                        },
                        "recipe": {
                            "recipe-index-read": (1, 1),
                            "recipe-document-read": (1, 2),
                        },
                        "mail": {"fixture-mail-accepted": (1, 1)},
                        "push": {"fixture-push-accepted": (1, 1)},
                    }[action]
                    require(
                        all(
                            low <= row["permit_effect_counts"].get(effect, 0) <= high
                            for effect, (low, high) in limits.items()
                        ),
                        "required_native_feature_effect_count",
                    )
                    if action == "calendar-sync":
                        require(
                            row["permit"]["feed_events"] == 2
                            and row["permit"]["field_changes"] == 2
                            and row["permit"]["suggestions"] == 1,
                            "calendar_sync_reconciliation_not_exercised",
                        )
                    if action == "firestore-guests":
                        require(
                            row["permit"]["count"] == 2,
                            "firestore_pagination_not_exercised",
                        )
                    row["denials"] = []
                    for label, arguments, prohibited_effects in denials:
                        start = len(counts())
                        outcome = process.call(action, **arguments)
                        observed = counts()[start:]
                        require(
                            outcome.get("ok") is False,
                            "required_native_feature_deny_failed",
                        )
                        require(
                            not any(
                                event.get("effect") in prohibited_effects
                                for event in observed
                            ),
                            "denied_native_feature_had_effect",
                        )
                        if action == "calendar-sync":
                            require(
                                outcome.get("schedule_unchanged") is True
                                and outcome.get("persisted_result_matches") is True,
                                "calendar_failure_changed_operation",
                            )
                        row["denials"].append(
                            {
                                "case": label,
                                "outcome": outcome,
                                "destinations": observed,
                                "prohibited_effects": sorted(prohibited_effects),
                                "prohibited_effect_count": 0,
                            }
                        )
                    start = len(counts())
                    row["recovery"] = process.call(action)
                    row["recovery_destinations"] = counts()[start:]
                    require(
                        row["recovery"].get("ok") is True,
                        "required_native_feature_recovery_failed",
                    )

                required_features = [
                    (
                        "calendar-sync",
                        {"calendar-read"},
                        [
                            "schedule_matches",
                            "protected_fields_unchanged",
                            "persisted_result_matches",
                        ],
                        [
                            (
                                "invalid-feed-credential",
                                {"badCredential": True},
                                {"calendar-read"},
                            )
                        ],
                    ),
                    (
                        "firestore-guests",
                        {"firestore-guest-page", "firestore-event-read"},
                        ["going"],
                        [
                            (
                                "invalid-refresh",
                                {"badCredential": True},
                                {"firestore-guest-page", "firestore-event-read"},
                            ),
                            (
                                "foreign-event",
                                {"foreignEvent": True},
                                {"firestore-guest-page", "firestore-event-read"},
                            ),
                        ],
                    ),
                    (
                        "firestore-schedule",
                        {"firestore-event-read", "firestore-schedule-write"},
                        ["duration_preserved"],
                        [
                            (
                                "invalid-refresh",
                                {"badCredential": True},
                                {"firestore-schedule-write"},
                            ),
                            (
                                "foreign-event",
                                {"foreignEvent": True},
                                {"firestore-schedule-write"},
                            ),
                        ],
                    ),
                    (
                        "partiful-upload",
                        {"partiful-image-upload"},
                        ["valid_upload"],
                        [
                            (
                                "invalid-refresh",
                                {"badCredential": True},
                                {"partiful-image-upload"},
                            )
                        ],
                    ),
                    (
                        "external-issuer",
                        {"issuer-jwks"},
                        ["exact_identity"],
                        [
                            (name, {"variant": name}, set())
                            for name in (
                                "wrong-audience",
                                "wrong-issuer",
                                "missing-scope",
                                "expired",
                                "tampered",
                            )
                        ],
                    ),
                    (
                        "pocketid-admin",
                        {
                            "admin-group-read",
                            "admin-signup-mint",
                            "admin-signup-delete",
                        },
                        [
                            "secret_received_in_memory",
                            "deleted",
                            "repeat_delete_idempotent",
                        ],
                        [
                            (
                                "invalid-admin-key",
                                {"badCredential": True},
                                {"admin-signup-mint", "admin-signup-delete"},
                            ),
                            (
                                "invalid-lifetime",
                                {"invalidTtl": True},
                                {"admin-signup-mint"},
                            ),
                            (
                                "ungranted-group",
                                {"foreignGroup": True},
                                {"admin-signup-mint"},
                            ),
                        ],
                    ),
                    (
                        "recipe",
                        {"recipe-index-read", "recipe-document-read"},
                        ["parsed_native_shape"],
                        [
                            (
                                "unknown-reference",
                                {"unknownRef": True},
                                {"recipe-document-read"},
                            )
                        ],
                    ),
                    (
                        "mail",
                        {"fixture-mail-accepted"},
                        ["native_receipt"],
                        [
                            (
                                "invalid-mail-key",
                                {"badCredential": True},
                                {"fixture-mail-accepted"},
                            ),
                            (
                                "invalid-recipient",
                                {"badRecipient": True},
                                {"fixture-mail-accepted"},
                            ),
                        ],
                    ),
                    (
                        "push",
                        {"fixture-push-accepted"},
                        ["configured", "foreign_delete_refused", "owner_preserved"],
                        [
                            (
                                "invalid-subscription-auth",
                                {"badCredential": True},
                                {"fixture-push-accepted"},
                            )
                        ],
                    ),
                ]
                for (
                    action,
                    expected_effects,
                    required_fields,
                    denials,
                ) in required_features:
                    case(
                        "T16-required-" + action,
                        lambda row,
                        action=action,
                        expected_effects=expected_effects,
                        required_fields=required_fields,
                        denials=denials: (
                            feature_pair(
                                row,
                                action,
                                expected_effects,
                                required_fields,
                                denials,
                            )
                        ),
                    )
                case(
                    "T16-reference-fetch",
                    lambda row: (
                        row.update(
                            permit=process.call(
                                "reference",
                                url="https://media.atrium.invalid/reference.png",
                            )
                        ),
                        require(row["permit"].get("ok"), "reference_not_permitted"),
                    ),
                )
                case(
                    "T16-openai-reference-edit",
                    lambda row: (
                        row.update(
                            permit=process.call(
                                "image", provider="openai", reference=True
                            )
                        ),
                        require(
                            row["permit"].get("ok"), "reference_edit_not_permitted"
                        ),
                    ),
                )
                case(
                    "address-granularity-cohost",
                    lambda row: (
                        row.update(
                            permit=process.call(
                                "fetch", url="https://cohost-undeclared.atrium.invalid/"
                            )
                        ),
                        require(
                            row["permit"].get("status") == 200,
                            "cohost_limit_not_observed",
                        ),
                    ),
                )
                case(
                    "provider-exception-not-image-only",
                    lambda row: (
                        row.update(
                            permit=process.call(
                                "fetch",
                                url="https://api.openai.com/v1/chat/completions",
                                method="POST",
                                useOpenaiKey=True,
                            )
                        ),
                        require(
                            row["permit"].get("status") == 200,
                            "provider_modality_limit_not_observed",
                        ),
                    ),
                )
                evidence["kernel_rules_after"] = process.call("rules")
                evidence["upstream_counts"] = counts()
            finally:
                process.close()
        evidence["bounded_n06_gate"] = (
            "passed"
            if all(row["status"] == "passed" for row in evidence["cases"])
            else "incomplete"
        )

    native.Resources = OwnedResources
    logging.disable(logging.CRITICAL)
    try:
        native.run(
            result,
            result["run_id"],
            checkpoint=writer.publish,
            configure=configure,
            prepare_fixture=prepare,
            exercise_adapter=exercise,
            provider_alias="personal.models.atrium.invalid",
        )
        result["status"] = (
            "passed" if result.get("bounded_n06_gate") == "passed" else "partial"
        )
    except Exception as error:  # noqa: BLE001 - preserve exact cleanup and redact failures
        result.update(
            status="failed", error=getattr(error, "code", type(error).__name__)
        )
    finally:
        logging.disable(logging.NOTSET)
        result["source_unchanged"] = result["source"]["commit"] == git(
            ROOT, "rev-parse", "HEAD"
        ).decode().strip() and all(
            hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == value["digest"]
            for name, value in result["source"]["files"].items()
        )
        if not result["source_unchanged"]:
            result.update(status="failed", error="n06_source_changed_during_run")
        writer.publish()
    print(
        json.dumps(
            {
                "ticket": "ATR-N06",
                "status": result["status"],
                "evidence": str(args.evidence),
            }
        )
    )
    return 0 if result["status"] == "passed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
