"""One credential POST per topology; observe real native worker readback only."""

import argparse
import hashlib
import json
import secrets
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import httpx

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = "/run/atrium-n04-readback"
PUBLIC_NATIVE_REVISION = "10f4033437df30b91b5dbf2b64711d0a8683fc52"
BOOT = """
import json,os,pathlib,sys
root=pathlib.Path(sys.argv[1])
os.umask(0o077)
data=json.loads(sys.stdin.readline())
(root/"readback_observer.py").write_text(data.pop("observer"))
os.environ.update(data["environment"])
os.environ["PYTHONPATH"]=str(root)
os.environ["TMPDIR"]=str(root)
os.environ["LITELLM_WORKER_STARTUP_HOOKS"]="readback_observer:install"
# Spawned workers reopen the config; a process-local descriptor is not sufficient.
config=root/"gateway.json"
with config.open("x") as output: json.dump(data["config"],output)
os.execv("/app/docker/prod_entrypoint.sh",["docker/prod_entrypoint.sh","--config",
 str(config),"--host","0.0.0.0","--port","4000","--num_workers",str(data["workers"])])
"""
PROBE = """
import hashlib,importlib.metadata,json,os,pathlib
os.environ.update(LITELLM_LOCAL_MODEL_COST_MAP="True",LITELLM_TELEMETRY="False",DO_NOT_TRACK="1")
import litellm
from litellm.constants import PROXY_CONFIG_RELOAD_INTERVAL_SECONDS
root=pathlib.Path(litellm.__file__).parent
paths=["proxy/credential_endpoints/endpoints.py","litellm_core_utils/credential_accessor.py",
 "proxy/proxy_server.py","repositories/credentials_repository.py","proxy/common_utils/config_sync_pubsub.py"]
print(json.dumps({"version":importlib.metadata.version("litellm"),
 "default_reload_seconds":PROXY_CONFIG_RELOAD_INTERVAL_SECONDS,
 "files":{name:{"algorithm":"sha256","digest":hashlib.sha256((root/name).read_bytes()).hexdigest()} for name in paths}}))
"""


def fingerprint(value):
    return {
        "algorithm": "sha256",
        "digest": hashlib.sha256(
            json.dumps(
                value, sort_keys=True, separators=(",", ":"), allow_nan=False
            ).encode()
        ).hexdigest(),
    }


def file_fingerprint(path):
    return {
        "algorithm": "sha256",
        "digest": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def classify(document, credential_name, expected):
    from atrium_litellm.errors import ControllerError, require

    require(document.get("success") is True, "incomplete_native_credentials")
    rows = document.get("credentials")
    require(isinstance(rows, list), "incomplete_native_credentials")
    matches = [row for row in rows if row.get("credential_name") == credential_name]
    require(len(matches) <= 1, "duplicate_native_credential")
    present = bool(matches)
    info = matches[0].get("credential_info") if present else None
    equal = info == expected
    try:
        require(equal, "native_credential_not_applied")
        guard = "accepted"
    except ControllerError as error:
        guard = error.code
    return {
        "row_present": present,
        "classification": "matching"
        if equal
        else "metadata-mismatch"
        if present
        else "missing-row",
        "metadata_type": type(info).__name__,
        "metadata_fields": sorted(info) if isinstance(info, dict) else [],
        "metadata_field_types": {
            name: type(value).__name__ for name, value in info.items()
        }
        if isinstance(info, dict)
        else {},
        "metadata_fingerprint": fingerprint(info) if present else None,
        "expected_fingerprint": fingerprint(expected),
        "metadata_equal": equal,
        "actual_equality_guard": guard,
    }


def configuration():
    return {
        "model_list": [],
        "general_settings": {
            "master_key": "os.environ/LITELLM_MASTER_KEY",
            "database_url": "os.environ/DATABASE_URL",
            "store_model_in_db": True,
            "disable_spend_logs": True,
        },
        "litellm_settings": {
            "cache": True,
            "cache_params": {"type": "local", "ttl": 60},
            "set_verbose": False,
            "turn_off_message_logging": True,
            "success_callback": [],
            "failure_callback": [],
        },
        "router_settings": {
            "num_retries": 0,
            "max_fallbacks": 0,
            "fallbacks": [],
            "context_window_fallbacks": [],
            "content_policy_fallbacks": [],
        },
    }


def observed(response, expected_pid=None):
    from harness.common import require

    pid = response.headers.get("x-atrium-readback-pid", "")
    poll = response.headers.get("x-atrium-readback-poll", "")
    require(pid.isdecimal() and poll.isdecimal(), "native_worker_observation_missing")
    require(expected_pid is None or int(pid) == expected_pid, "worker_affinity_changed")
    require(
        response.headers.get("x-atrium-readback-redis") == "0",
        "unexpected_native_redis",
    )
    require(int(poll) == 30, "pinned_native_poll_interval_changed")
    return {
        "pid": int(pid),
        "status": response.status_code,
        "reload_seconds": int(poll),
        "redis": False,
    }


def connection(endpoint):
    return httpx.Client(
        base_url=endpoint,
        trust_env=False,
        follow_redirects=False,
        timeout=15,
        limits=httpx.Limits(
            max_connections=1, max_keepalive_connections=1, keepalive_expiry=None
        ),
    )


def management_identity(endpoint, master, control, control_routes, operations):
    from atrium_litellm.errors import require
    from atrium_litellm.native import Native

    # Native.key deliberately refuses inspection of its own management key.
    bootstrap = Native(endpoint, master, operations=operations)
    info = bootstrap.key(hashlib.sha256(control.encode()).hexdigest())
    require(
        sorted(info.get("allowed_routes", [])) == control_routes,
        "native_control_routes_mismatch",
    )
    require(
        info.get("user_id") == "n03-controller-control",
        "native_control_identity_mismatch",
    )
    return {
        "native_user_id": "n03-controller-control",
        "verified_role": "proxy_admin",
        "key_type": "default",
        "routes": control_routes,
        "master_used_for_control_verification": True,
        "master_used_for_credential_readback": False,
    }


def exercise(endpoint, master, workers, result, checkpoint):
    from atrium_litellm.controller import Controller
    from atrium_litellm.native import CONTROL_ROUTES, Native
    from harness.common import require
    from harness.litellm_native import wait_http

    master_headers = {"Authorization": "Bearer " + master}
    control_routes = sorted(set().union(*CONTROL_ROUTES.values()) | {"/key/delete"})
    with connection(endpoint) as bootstrap:
        wait_http(bootstrap, "/v1/models", master_headers)
        user = bootstrap.post(
            "/user/new",
            headers=master_headers,
            json={
                "user_id": "n03-controller-control",
                "user_role": "proxy_admin",
                "auto_create_key": False,
            },
        )
        require(
            user.status_code == 200 and user.json().get("user_role") == "proxy_admin",
            "native_control_user_failed",
        )
        created = bootstrap.post(
            "/key/generate",
            headers=master_headers,
            json={
                "user_id": "n03-controller-control",
                "duration": "30m",
                "key_type": "default",
                "allowed_routes": control_routes,
            },
        )
        require(created.status_code == 200, "native_control_creation_failed")
        control = created.json()["key"]
    native = Native(
        endpoint, control, operations=result.setdefault("native_client_operations", [])
    )
    native.inspect_gateway()
    result["management"] = management_identity(
        endpoint, master, control, control_routes, result["native_client_operations"]
    )
    headers = {"Authorization": "Bearer " + control, "Connection": "keep-alive"}
    pool = {}
    try:
        for _ in range(48):
            for pid, active in pool.items():
                observed(active.get("/credentials", headers=headers), pid)
            candidate = connection(endpoint)
            response = candidate.get("/credentials", headers=headers)
            observation = observed(response)
            require(response.status_code == 200, "native_control_read_refused")
            if observation["pid"] in pool:
                candidate.close()
            else:
                pool[observation["pid"]] = candidate
            if len(pool) == workers:
                break
            time.sleep(0.1)
        require(len(pool) == workers, "native_workers_not_reached")
        result["worker_pids"] = sorted(pool)
        writer_pid = sorted(pool)[0]
        identifier = "cc.readback." + secrets.token_hex(12)
        logical = "cc.readback.provider"
        controller = object.__new__(Controller)
        controller.ledger = SimpleNamespace(installation="cc.readback." + str(workers))
        controller.desired = SimpleNamespace(
            document={
                "service_credentials": {
                    logical: {
                        "domain": "personal:fixture",
                        "provider": "fixture-provider",
                        "account": "fixture-account",
                    }
                }
            }
        )
        expected = controller._credential_info(logical)
        result["credential_name_fingerprint"] = fingerprint(identifier)
        result["expected_metadata_fields"] = sorted(expected)
        result["expected_metadata_fingerprint"] = fingerprint(expected)
        started = time.monotonic()
        response = pool[writer_pid].post(
            "/credentials",
            headers=headers,
            json={
                "credential_name": identifier,
                "credential_values": {"api_key": secrets.token_urlsafe(32)},
                "credential_info": expected,
            },
        )
        result["creation"] = {
            **observed(response, writer_pid),
            "elapsed_ms": round((time.monotonic() - started) * 1000),
            "posts": 1,
        }
        require(
            response.status_code == 200 and response.json().get("success") is True,
            "native_credential_creation_failed",
        )
        result["readbacks"] = []
        interval = result["creation"]["reload_seconds"]
        budget = interval * 2 + 3
        result["timing_budget"] = {
            "native_reload_seconds": interval,
            "poll_period_seconds": 3,
            "deadline_seconds": budget,
            "native_poll_or_clock_modified": False,
        }
        next_read = time.monotonic()
        while True:
            round_rows = []
            for pid, client in pool.items():
                response = client.get("/credentials", headers=headers)
                row = {
                    **observed(response, pid),
                    "writer": pid == writer_pid,
                    "elapsed_ms": round((time.monotonic() - started) * 1000),
                }
                if response.status_code != 200:
                    row["classification"] = "native-auth-or-route-refusal"
                else:
                    row.update(classify(response.json(), identifier, expected))
                result["readbacks"].append(row)
                round_rows.append(row)
            checkpoint()
            require(
                all(row["status"] == 200 for row in round_rows),
                "native_readback_refused",
            )
            if all(row["metadata_equal"] for row in round_rows):
                result["all_workers_converged"] = True
                break
            if time.monotonic() - started >= budget:
                result["all_workers_converged"] = False
                break
            next_read += 3
            time.sleep(max(0, next_read - time.monotonic()))
        first = result["readbacks"][:workers]
        result["outcome"] = {
            "writer_immediate_match": next(
                row["metadata_equal"] for row in first if row["writer"]
            ),
            "other_worker_initially_missing": any(
                not row["writer"] and row["classification"] == "missing-row"
                for row in first
            ),
            "present_metadata_mismatch_observed": any(
                row["classification"] == "metadata-mismatch"
                for row in result["readbacks"]
            ),
            "eventual_exact_convergence": result["all_workers_converged"],
            "provider_or_inference_calls": 0,
        }
    finally:
        for client in pool.values():
            client.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    sys.path[:0] = [str(args.harness), str(ROOT / "pkgs/atrium-litellm-controller")]
    from harness.common import Blocked, EvidenceWriter, PINS, require
    from harness.containers import Resources
    from harness.litellm_native import POSTGRES_BOOT

    def git(*arguments):
        return subprocess.run(
            ["git", "-C", str(ROOT), *arguments],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    require(not git("status", "--porcelain"), "clean_diagnostic_source_required")
    require(
        args.evidence.resolve().is_relative_to(ROOT / "tests/atrium_n04/results")
        and not args.evidence.exists(),
        "new_diagnostic_receipt_required",
    )
    paths = [
        ROOT / "tests/atrium_n04" / name
        for name in (
            "readback_diagnostic.py",
            "readback_observer.py",
            "test_readback_diagnostic.py",
            "readback-source-pins.json",
        )
    ]
    paths += list((ROOT / "pkgs/atrium-litellm-controller/atrium_litellm").glob("*.py"))
    identity = {str(path.relative_to(ROOT)): file_fingerprint(path) for path in paths}
    native_pins = json.loads(
        (ROOT / "tests/atrium_n04/readback-source-pins.json").read_bytes()
    )
    require(
        native_pins["revision"] == PUBLIC_NATIVE_REVISION,
        "native_source_pin_revision_changed",
    )
    result = {
        "ticket": "ATR-N04",
        "run_id": "credential-readback-" + secrets.token_hex(8),
        "status": "running",
        "source": {
            "commit": git("rev-parse", "HEAD"),
            "dirty": False,
            "files": identity,
            "harness_files": {
                name: file_fingerprint(args.harness / "harness" / name)
                for name in (
                    "containers.py",
                    "litellm_native.py",
                    "common.py",
                    "pins.json",
                )
            },
            "owner_spec": file_fingerprint(args.spec),
        },
        "topologies": [],
        "scope": "Native credential create/readback only; no inference or controller guard changes",
    }
    writer = EvidenceWriter(args.evidence, result)

    def inventory(resources):
        return {
            "containers": sorted(
                resources.command(
                    ["ps", "--all", "--format", "{{.ID}}|{{.Names}}|{{.State}}"]
                ).splitlines()
            ),
            "networks": sorted(
                resources.command(
                    ["network", "ls", "--format", "{{.ID}}|{{.Name}}"]
                ).splitlines()
            ),
            "volumes": sorted(
                resources.command(
                    ["volume", "ls", "--format", "{{.Name}}"]
                ).splitlines()
            ),
            "images": sorted(
                {
                    value.removeprefix("sha256:")
                    for value in resources.command(
                        ["images", "--no-trunc", "--format", "{{.ID}}"]
                    ).splitlines()
                }
            ),
        }

    for workers in (1, 2):
        row = {"workers": workers, "status": "running"}
        result["topologies"].append(row)
        resources = Resources(
            result["run_id"] + "-" + str(workers), row, writer.publish
        )
        resources.select_local_engine()
        row["before"] = inventory(resources)
        require(
            not any(
                line.split("|")[2] == "running" and line.split("|")[1] != "ambit-db"
                for line in row["before"]["containers"]
            ),
            "shared_native_vm_busy",
        )
        try:
            arch = json.loads(resources.command(["info", "--format", "json"]))["host"][
                "arch"
            ]
            image = resources.image(PINS["litellm"]["image"], "linux/" + arch)
            database_image = resources.image(
                PINS["postgres"]["image"], PINS["postgres"]["platform"]
            )
            row["images"] = {"litellm": image, "postgres": database_image}
            require(
                "ghcr.io/berriai/litellm@" + PINS["litellm"]["platform_manifests"][arch]
                in image["repo_digests"],
                "native_platform_manifest_mismatch",
            )
            require(
                image["image_id"] in row["before"]["images"]
                and database_image["image_id"] in row["before"]["images"],
                "preexisting_pinned_images_required",
            )
            resources.create_network()
            password, master = (
                secrets.token_urlsafe(32),
                "sk-" + secrets.token_urlsafe(32),
            )
            database = resources.create(
                "postgres",
                database_image["image_id"],
                "/bin/sh",
                ["-c", POSTGRES_BOOT],
                memory="1024m",
                options=(
                    "--tmpfs",
                    "/var/lib/postgresql/data:rw,nosuid,nodev,noexec,size=768m,mode=0700",
                ),
            )
            resources.start(database, password)
            resources.wait_running(database)
            ready_until = time.monotonic() + 60
            while True:
                try:
                    resources.command(
                        [
                            "exec",
                            database,
                            "pg_isready",
                            "-U",
                            "atrium_fixture",
                            "-d",
                            "atrium_fixture",
                        ]
                    )
                    break
                except Blocked:
                    if time.monotonic() >= ready_until:
                        raise
                    time.sleep(1)
            gateway = resources.create(
                "gateway",
                image["image_id"],
                "python",
                ["-B", "-c", BOOT, RUNTIME],
                memory="3072m",
                cpus="2",
                port=4000,
                options=("--tmpfs", RUNTIME + ":rw,nosuid,nodev,size=32m,mode=0700"),
            )
            resources.start(
                gateway,
                json.dumps(
                    {
                        "observer": (
                            ROOT / "tests/atrium_n04/readback_observer.py"
                        ).read_text(),
                        "workers": workers,
                        "config": configuration(),
                        "environment": {
                            "DATABASE_URL": f"postgresql://atrium_fixture:{password}@{resources.prefix}-postgres:5432/atrium_fixture?connection_limit=5",
                            "LITELLM_MASTER_KEY": master,
                            "LITELLM_LOCAL_MODEL_COST_MAP": "True",
                            "LITELLM_TELEMETRY": "False",
                            "DO_NOT_TRACK": "1",
                            "LITELLM_LOG": "ERROR",
                        },
                    }
                ),
            )
            resources.wait_running(gateway)
            row["native_source"] = json.loads(
                resources.command(["exec", gateway, "python", "-B", "-c", PROBE])
            )
            require(
                row["native_source"]["version"] == "1.99.1"
                and row["native_source"]["default_reload_seconds"] == 30
                and row["native_source"]["files"] == native_pins["files"],
                "native_version_source_or_poll_mismatch",
            )
            exercise(
                resources.endpoint(gateway, 4000), master, workers, row, writer.publish
            )
            row["status"] = "completed"
        except Exception as error:
            row.update(
                status="failed", error_code=getattr(error, "code", type(error).__name__)
            )
            result["status"] = "failed"
            raise
        finally:
            resources.cleanup()
            row["after"] = inventory(resources)
            row["inventories_equal"] = row["before"] == row["after"]
            row["source_unchanged"] = identity == {
                str(path.relative_to(ROOT)): file_fingerprint(path) for path in paths
            }
            row["source_unchanged"] = (
                row["source_unchanged"]
                and git("rev-parse", "HEAD") == result["source"]["commit"]
                and result["source"]["harness_files"]
                == {
                    name: file_fingerprint(args.harness / "harness" / name)
                    for name in result["source"]["harness_files"]
                }
                and file_fingerprint(args.spec) == result["source"]["owner_spec"]
            )
            writer.publish()
            require(
                row["inventories_equal"] and row["source_unchanged"],
                "diagnostic_inventory_or_source_changed",
            )
    result["status"] = "completed"
    result["lag_hypothesis_confirmed"] = (
        result["topologies"][0]["outcome"]["writer_immediate_match"]
        and result["topologies"][1]["outcome"]["writer_immediate_match"]
        and result["topologies"][1]["outcome"]["other_worker_initially_missing"]
        and result["topologies"][1]["outcome"]["eventual_exact_convergence"]
        and not any(
            row["outcome"]["present_metadata_mismatch_observed"]
            for row in result["topologies"]
        )
    )
    writer.publish()
    print(
        json.dumps(
            {
                "status": result["status"],
                "lag_hypothesis_confirmed": result["lag_hypothesis_confirmed"],
                "evidence": str(args.evidence),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
