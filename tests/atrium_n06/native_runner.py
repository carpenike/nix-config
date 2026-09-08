"""Actual W03/N04/native gateway under invocation-owned N06 namespace enforcement."""

import argparse
import hashlib
import json
import logging
import secrets
import select
import subprocess
import sys
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tests/atrium_n05"))
from supervisor import git, inventory, load_harness  # noqa: E402

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
    args = parser.parse_args()
    native, harness_hashes = load_harness(args.harness)
    from harness.common import EvidenceWriter, require
    from harness.containers import Resources

    require(
        args.evidence.resolve().is_relative_to(HERE / "results")
        and not args.evidence.exists(),
        "new_n06_evidence_path_required",
    )
    whiskey_files = (
        "server/lib/anthropic.ts",
        "server/lib/atrium-model.ts",
        "server/lib/image-gen.ts",
        "server/lib/safe-fetch.ts",
        "server/lib/oidc.ts",
        "server/integrations/partiful-firebase.ts",
        "server/lib/plex.ts",
        "package.json",
        "package-lock.json",
        "scripts/atrium-w03/provider.py",
    )
    for name in whiskey_files:
        require(
            git(
                args.whiskey, "show", "c26e318c8c67d8051bf58f369d4b69dbaf998538:" + name
            )
            == (args.whiskey / name).read_bytes(),
            "whiskey_immutable_source_mismatch",
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
            "consumer_commit": git(args.whiskey, "rev-parse", "HEAD").decode().strip(),
            "consumer_implementation": "c26e318c8c67d8051bf58f369d4b69dbaf998538",
            "whiskey_files": {
                name: {
                    "algorithm": "sha256",
                    "digest": hashlib.sha256(
                        (args.whiskey / name).read_bytes()
                    ).hexdigest(),
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
            "compiled_runtime": json.loads(
                (ROOT / ".artifacts/n06-whiskey-runtime/build.json").read_text()
            ),
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
        )
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
                    (args.whiskey / "scripts/atrium-w03/provider.py").read_text(),
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
                }
            ),
        )
        resources.wait_running(upstreams)
        endpoint = resources.endpoint(upstreams, 8000)
        with httpx.Client(base_url=endpoint, trust_env=False, timeout=10) as client:
            headers = {"Authorization": "Bearer " + upstream_observer}
            native.wait_http(client, "/state", headers, seconds=45)
            state["ca"] = client.get("/ca", headers=headers).text
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
except Exception as error:
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
                "actual_helper": "compiled W03 callAnthropic and native image adapters",
                "egress": "UID-scoped nftables in exact invocation-owned network namespace",
                "granularity": "IPv4 destination address + TCP port; not hostname or image-only enforcement",
                "registry": "N04 isolated registry with N06 isolated overlays; one generated policy",
                "provider_exceptions": "OpenAI/Gemini/OpenRouter remain direct",
                "production_reference_policy": "unresolved; arbitrary public reference/push endpoints need owner-approved policy",
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
                except Exception as error:
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

                    def image(row):
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
                        lambda row: (
                            row.update(permit=process.call(action)),
                            require(row["permit"].get("ok"), "non_model_not_permitted"),
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
    except Exception as error:
        result.update(
            status="failed", error=getattr(error, "code", type(error).__name__)
        )
    finally:
        logging.disable(logging.NOTSET)
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
