"""Actual owned-admission integration using the existing pinned native supervisor."""

import argparse
import base64
import hashlib
import json
import logging
import secrets
import signal
import subprocess
import time
from pathlib import Path

import httpx

from supervisor import ROOT, git, inventory, load_harness

PRODUCT = "1d620cd30f27f2b5849533fb2a9bdb5016385f69"
RUNTIME = "/run/atrium-n05"
BOOT = """
import base64,io,pathlib,zipfile
root=pathlib.Path("/run/atrium-n05")
for name,encoded in data.pop("wheels").items():
 with zipfile.ZipFile(io.BytesIO(base64.b64decode(encoded))) as wheel:
  wheel.extractall(root/"python")
(root/"admission_loader.py").write_text(data.pop("observer_source"))
config=root/"config.json"
config.write_text(json.dumps(data["config"]))
config.chmod(0o600)
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    native, harness_hashes = load_harness(args.harness)
    from harness.common import EvidenceWriter, HarnessError, require
    from harness.containers import Resources

    output = args.evidence.resolve()
    require(
        output.is_relative_to(ROOT / "tests/atrium_n05/results"),
        "evidence_path_refused",
    )
    result = {
        "ticket": "ATR-N05",
        "run_id": "n05-adapter-" + secrets.token_hex(8),
        "status": "running",
        "full_n05": "incomplete",
        "source": {
            "commit": git(ROOT, "rev-parse", "HEAD").decode().strip(),
            "dirty": bool(git(ROOT, "status", "--porcelain").strip()),
            "product_revision": PRODUCT,
            "shared_harness": harness_hashes,
            "owner_spec_sha256": hashlib.sha256(args.spec.read_bytes()).hexdigest(),
            "files": {
                str(p.relative_to(ROOT)): {
                    "algorithm": "sha256",
                    "digest": hashlib.sha256(p.read_bytes()).hexdigest(),
                }
                for directory in (
                    ROOT / "pkgs/atrium-litellm-admission",
                    ROOT / "tests/atrium_n05",
                )
                for p in sorted(directory.rglob("*.py"))
                if ".artifacts" not in p.parts
            },
        },
    }
    writer = EvidenceWriter(output, result)
    wheels = {
        p.name: base64.b64encode(p.read_bytes()).decode()
        for p in (ROOT / ".artifacts/admission-wheels").glob("*.whl")
    }
    require(len(wheels) == 4, "actual_admission_wheels_missing")
    state = {}
    original_boot = native.LITELLM_BOOT
    native.LITELLM_BOOT = (
        original_boot.replace('"--num_workers", "1"', '"--num_workers", "2"')
        .replace(
            'os.environ.update(data["environment"])',
            BOOT + '\nos.environ.update(data["environment"])',
        )
        .replace('"/proc/self/fd/" + str(fd)', '"/run/atrium-n05/config.json"')
    )

    class ObservedResources(Resources):
        def select_local_engine(self):
            super().select_local_engine()
            state["resources"] = self
            state["before"] = inventory(self)
            self.result["foreign_before"] = state["before"]
            require(
                not any(
                    row["state"] == "running" and row["name"] != "ambit-db"
                    for row in state["before"].values()
                ),
                "shared_native_vm_busy",
            )

        def create(self, role, image, entrypoint, args, **kwargs):
            if role == "provider":
                args = ["-B", "-c", (ROOT / "tests/atrium_n05/provider.py").read_text()]
            if role == "litellm":
                kwargs["options"] = (
                    *kwargs.get("options", ()),
                    "--tmpfs",
                    RUNTIME + ":rw,nosuid,nodev,noexec,size=64m,mode=0700",
                    "--publish",
                    "127.0.0.1::9010",
                    "--publish",
                    "127.0.0.1::8765",
                )
            identifier = super().create(role, image, entrypoint, args, **kwargs)
            if role == "litellm":
                state["gateway"] = identifier
            return identifier

        def start(self, identifier, payload=""):
            role = next(
                row["role"]
                for row in self.result["resources"]
                if row.get("id") == identifier
            )
            if role == "provider":
                state["observer_key"] = json.loads(payload)["observer"]
            if identifier == state.get("gateway"):
                data = json.loads(payload)
                data["wheels"] = wheels
                data["observer_source"] = (
                    ROOT / "tests/atrium_n05/observed_admission.py"
                ).read_text()
                data["environment"].update(
                    {
                        "PYTHONPATH": RUNTIME + "/python",
                        "ATRIUM_ADMISSION_SETTINGS": RUNTIME
                        + "/admission-settings.json",
                        "N05_OBSERVER_URL": "http://" + self.prefix + "-provider:8000",
                        "N05_OBSERVER_KEY": state["observer_key"],
                    }
                )
                payload = json.dumps(data)
            return super().start(identifier, payload)

        def cleanup(self):
            super().cleanup()
            after = inventory(self)
            self.result["foreign_after"] = {
                key: after.get(key) for key in state.get("before", {})
            }
            require(
                self.result["foreign_after"] == state.get("before", {}),
                "foreign_resource_changed",
            )
            self.result["foreign_resources_unchanged"] = True
            self.publish()

    original_configuration = native.configuration

    def configure(provider):
        config = original_configuration(provider)
        for model in config["model_list"]:
            model["model_name"] = (
                "cc." + model["model_name"].removesuffix("-fixture") + ".text"
            )
        config["litellm_settings"].update(
            {
                "cache": True,
                "cache_params": {"type": "local", "ttl": 600},
                "callbacks": ["admission_loader.admission"],
            }
        )
        return config

    def exercise(
        client, observer, control, observer_headers, evidence, run_id, checkpoint
    ):
        resources = state["resources"]
        fixture_token = secrets.token_urlsafe(32)
        code = (ROOT / "tests/atrium_n05/admission_fixture.py").read_text()
        loader = """
import io,json,pathlib,sys,traceback
sys.path.insert(0,"/run/atrium-n05/python")
data=json.loads(sys.stdin.readline())
source=data.pop("code")
sys.stdin=io.StringIO(json.dumps(data)+"\\n")
try:
 exec(compile(source,"admission_fixture.py","exec"))
except Exception as error:
 frame=traceback.extract_tb(error.__traceback__)[-1]
 print(json.dumps({"error":"fixture_startup_failed","exception":type(error).__name__,
                  "file":pathlib.Path(frame.filename).name,"line":frame.lineno}),flush=True)
 raise SystemExit(1) from None
"""
        argv = [
            *resources.prefix_command,
            "exec",
            "--interactive",
            state["gateway"],
            "python",
            "-B",
            "-c",
            loader,
        ]
        process = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        resources.processes.append(process)
        record = {
            "argv": argv,
            "status": "attached",
            "stdin": "not recorded; runtime fixture input",
        }
        resources.process_records.append(record)
        evidence["commands"].append(record)
        process.stdin.write(
            json.dumps(
                {
                    "code": code,
                    "master": control["Authorization"].removeprefix("Bearer "),
                    "fixture_control": fixture_token,
                    "policy": json.loads(
                        git(
                            args.harness,
                            "show",
                            PRODUCT + ":resolver/fixtures/policy.generated.json",
                        )
                    ),
                    "seed": json.loads(
                        git(
                            args.harness,
                            "show",
                            PRODUCT + ":resolver/fixtures/policy-seed.synthetic.json",
                        )
                    ),
                }
            )
            + "\n"
        )
        process.stdin.close()
        helper = httpx.Client(
            base_url=resources.endpoint(state["gateway"], 9010),
            trust_env=False,
            timeout=20,
        )
        try:
            try:
                native.wait_http(helper, "/ready", {}, seconds=30)
            except HarnessError:
                if process.poll() is not None:
                    evidence["fixture_startup"] = json.loads(process.stdout.read(65536))
                raise

            def action(name, **values):
                response = helper.post(
                    "/action",
                    headers={"Authorization": "Bearer " + fixture_token},
                    json={"action": name, **values},
                )
                if response.status_code != 200:
                    evidence["fixture_action_error"] = response.json()
                    checkpoint()
                    raise HarnessError("native_fixture_action_failed")
                return response.json()

            def counts():
                response = observer.get("/_fixture/counts", headers=observer_headers)
                require(response.status_code == 200, "observer_unavailable")
                return response.json()["received"]

            def infer(key, *, expected=200, nonce="default", stream=False):
                before = counts()
                response = client.post(
                    "/v1/chat/completions",
                    headers={"Authorization": "Bearer " + key["key"]},
                    json={
                        "model": key["model"],
                        "messages": [{"role": "user", "content": run_id + nonce}],
                        "stream": stream,
                        "max_tokens": 4,
                        "metadata": {
                            "principal": "forged-admin",
                            "native_owned": False,
                        },
                    },
                )
                delta = counts() - before
                require(
                    response.status_code == expected, "owned_native_admission_status"
                )
                if expected != 200:
                    require(
                        delta == 0 and "fixture-ok-n05" not in response.text,
                        "denied_native_effect",
                    )
                return {"status": response.status_code, "provider_requests": delta}

            action("feed", mode="missing")
            cold_child = action("mint", kind="child")
            cold_admin = action("mint", kind="admin")
            cold_service = action("mint", kind="service")
            cold_legacy = action("mint", kind="legacy")
            cold = {
                "id": "cold-missing-feed",
                "status": "passed",
                "child": infer(cold_child, expected=403, nonce="cold-child"),
                "admin": infer(cold_admin, nonce="cold-admin"),
                "service": infer(cold_service, expected=403, nonce="cold-service"),
                "non_owned": infer(cold_legacy, nonce="cold-legacy"),
            }
            require(action("status")["alerts"], "cold_admin_durable_alert_missing")
            evidence["cases"].append(cold)
            action("feed", mode="live")
            time.sleep(2)
            expiring = action("mint", kind="admin", native_seconds=5)
            before_expiry = infer(expiring, nonce="expiring")
            time.sleep(max(0, expiring["expires_at"] + 1 - time.time()))
            evidence["cases"].append(
                {
                    "id": "native-expiry-remains-native",
                    "status": "passed",
                    "permit": before_expiry,
                    "deny": infer(expiring, expected=401, nonce="expiring"),
                }
            )
            from protocol_cases import run_protocols

            run_protocols(
                client, observer, observer_headers, action, evidence, run_id, checkpoint
            )
            child = action("mint", kind="child")
            admin = action("mint", kind="admin")
            service = action("mint", kind="service")
            legacy = action("mint", kind="legacy")
            evidence["scope"].update(
                {
                    "actual_admission_package": True,
                    "shared_R04_cache": True,
                    "real_R07_feed": True,
                    "real_R06_N04_producers": True,
                    "full_R06_issuance": False,
                    "full_N04_reconciliation": False,
                    "workers": 2,
                    "output_cache": "native local",
                }
            )
            for name, key in (
                ("child", child),
                ("admin", admin),
                ("service", service),
                ("legacy", legacy),
            ):
                evidence["cases"].append(
                    {
                        "id": "positive-" + name,
                        "status": "passed",
                        "permit": infer(key, nonce=name),
                    }
                )
            for method, route in (
                ("GET", "/key/list"),
                ("GET", "/key/info"),
                ("GET", "/user/info"),
                ("GET", "/team/info"),
                ("POST", "/key/generate"),
                ("POST", "/key/delete"),
                ("POST", "/user/new"),
                ("POST", "/team/new"),
            ):
                response = client.request(
                    method,
                    route,
                    headers={"Authorization": "Bearer " + admin["key"]},
                    json={},
                )
                require(
                    response.status_code == 403, "native_management_separation_failed"
                )
                evidence["cases"].append(
                    {
                        "id": "management-" + method + "-" + route,
                        "status": "passed",
                        "native_owner": "proxy_admin",
                        "native_status": 403,
                    }
                )
            action("native_failure", value=True)
            action("feed", mode="capture")
            action("deny", hash=child["hash"])
            pending = action("drain")
            require(pending["pending"] > 0, "native_revoke_failure_not_pending")
            time.sleep(2)
            denied = infer(child, expected=403, nonce="child")
            evidence["cases"].append(
                {
                    "id": "native-failure-signed-deny",
                    "status": "passed",
                    "deny": denied,
                    "pending_native_work": True,
                    "non_owned": infer(legacy, nonce="legacy"),
                }
            )
            for mode in ("invalid", "replay"):
                action("feed", mode=mode)
                time.sleep(2)
                evidence["cases"].append(
                    {
                        "id": "feed-" + mode + "-retains-deny",
                        "status": "passed",
                        "deny": infer(child, expected=403, nonce="child"),
                    }
                )
            action("feed", mode="live")
            time.sleep(2)
            for producer in ("resolver", "services"):
                for mode in ("missing", "corrupt"):
                    action("producer", producer=producer, mode=mode)
                    rejected = infer(admin, expected=503, nonce="admin")
                    action("producer", producer=producer, mode="restore")
                    recovered = infer(admin, nonce="admin")
                    evidence["cases"].append(
                        {
                            "id": producer + "-" + mode,
                            "status": "passed",
                            "deny": rejected,
                            "permit": recovered,
                        }
                    )
            reservation = action("mint", kind="child")
            action("lifecycle", hash=reservation["hash"], status="reserved")
            rejected = infer(reservation, expected=403, nonce="reservation")
            action("lifecycle", hash=reservation["hash"], status="prepared")
            evidence["cases"].append(
                {
                    "id": "reserved-not-admission",
                    "status": "passed",
                    "deny": rejected,
                    "permit": infer(reservation, nonce="reservation"),
                }
            )
            action("producer", producer="resolver", mode="capture")
            newest = action("mint", kind="child")
            infer(newest, nonce="newest")
            action("producer", producer="resolver", mode="rollback")
            rejected = infer(newest, expected=503, nonce="newest")
            action("producer", producer="resolver", mode="restore")
            evidence["cases"].append(
                {
                    "id": "producer-rollback-not-legacy",
                    "status": "passed",
                    "deny": rejected,
                    "permit": infer(newest, nonce="newest"),
                }
            )
            action("deny", hash=admin["hash"])
            time.sleep(2)
            evidence["cases"].append(
                {
                    "id": "known-admin-deny",
                    "status": "passed",
                    "deny": infer(admin, expected=403, nonce="admin"),
                }
            )
            action("deny", hash=admin["hash"], value=False)
            action("feed", mode="signed-stale", age=301)
            time.sleep(2)
            stale_child = infer(child, expected=403, nonce="child")
            stale_service = infer(service, expected=403, nonce="service")
            stale_admin = infer(admin, nonce="admin")
            status = action("status")
            require(status["alerts"], "actual_durable_admin_alert_missing")
            evidence["cases"].append(
                {
                    "id": "stale-human-vs-service",
                    "status": "passed",
                    "child": stale_child,
                    "service": stale_service,
                    "admin": stale_admin,
                    "durable_alert_count": len(status["alerts"]),
                }
            )
            action("feed", mode="signed-stale", age=301, principals=["fixture-admin"])
            time.sleep(2)
            evidence["cases"].append(
                {
                    "id": "known-admin-denied-while-stale",
                    "status": "passed",
                    "deny": infer(admin, expected=403, nonce="admin"),
                }
            )
            checkpoint()
        finally:
            helper.close()

    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    for name in ("SIGINT", "SIGTERM"):
        signal.signal(getattr(signal, name), interrupted)
    native.Resources = ObservedResources
    logging.disable(logging.CRITICAL)
    try:
        native.run(
            result,
            result["run_id"],
            checkpoint=writer.publish,
            configure=configure,
            exercise_adapter=exercise,
        )
        result["status"] = "passed"
    except HarnessError as error:
        result.update(status="failed", error=error.code)
    except KeyboardInterrupt:
        result.update(status="interrupted")
    except Exception:
        result.update(status="failed", error="native_admission_fixture_failed")
    finally:
        logging.disable(logging.NOTSET)
        writer.publish()
    print(
        json.dumps(
            {
                "ticket": "ATR-N05",
                "status": result["status"],
                "evidence": str(output.relative_to(ROOT)),
            }
        )
    )
    return 0 if result["status"] == "passed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
