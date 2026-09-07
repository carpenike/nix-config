"""Actual owned-admission integration using the existing pinned native supervisor."""

import argparse
import hashlib
import json
import logging
import secrets
import signal
import time
from pathlib import Path

import httpx

from supervisor import ROOT, git, inventory, load_harness, verified_wheels

PRODUCT = "1d620cd30f27f2b5849533fb2a9bdb5016385f69"
RUNTIME = "/run/atrium-n05"
BOOT = """
import base64,http.client,io,pathlib,subprocess,time,zipfile
root=pathlib.Path("/run/atrium-n05")
for name,encoded in data.pop("wheels").items():
 with zipfile.ZipFile(io.BytesIO(base64.b64decode(encoded))) as wheel:
  wheel.extractall(root/"python")
(root/"admission_loader.py").write_text(data.pop("observer_source"))
config=root/"config.json"
config.write_text(json.dumps(data["config"]))
config.chmod(0o600)
fixture=root/"admission_fixture.py"
fixture.write_text(data.pop("fixture_source"))
helper=subprocess.Popen(
 [sys.executable,"-B",str(fixture)],stdin=subprocess.PIPE,
 stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True,
 env=os.environ|data["environment"],
)
helper.stdin.write(json.dumps(data.pop("fixture_inputs"))+"\\n")
helper.stdin.close()
for attempt in range(300):
 if helper.poll() is not None:
  raise RuntimeError("protected_fixture_startup_failed")
 connection=http.client.HTTPConnection("127.0.0.1",9010,timeout=1)
 try:
  connection.request("GET","/ready")
  response=connection.getresponse()
  ready=response.status==200
  response.read()
 except OSError:
  ready=False
 finally:
  connection.close()
 if ready:
  break
 time.sleep(0.1)
else:
 raise RuntimeError("protected_fixture_startup_timeout")
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--protocol-only", choices=("completions",))
    selection.add_argument("--review-only", action="store_true")
    selection.add_argument("--context-only", action="store_true")
    selection.add_argument("--post-auth-only", action="store_true")
    selection.add_argument("--post-auth-review-only", action="store_true")
    args = parser.parse_args()
    post_auth = args.post_auth_only or args.post_auth_review_only
    review = args.review_only or args.post_auth_review_only
    native, harness_hashes = load_harness(args.harness)
    from harness.common import EvidenceWriter, HarnessError, require
    from harness.containers import Resources

    output = args.evidence.resolve()
    require(
        output.is_relative_to(ROOT / "tests/atrium_n05/results"),
        "evidence_path_refused",
    )
    require(not output.exists(), "existing_evidence_refused")
    result = {
        "ticket": "ATR-N05",
        "run_id": "n05-adapter-" + secrets.token_hex(8),
        "status": "running",
        "full_n05": "incomplete",
        "selected_protocol": "post-native-auth-review"
        if args.post_auth_review_only
        else "review-faults"
        if review
        else "request-context"
        if args.context_only
        else "post-native-auth"
        if args.post_auth_only
        else args.protocol_only or "all-N02-allowed",
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
    result["command"] = [
        "python",
        "tests/atrium_n05/actual_native.py",
        "--harness",
        str(args.harness),
        "--spec",
        str(args.spec),
        "--evidence",
        str(args.evidence),
    ] + ([] if args.protocol_only is None else ["--protocol-only", args.protocol_only])
    if args.review_only:
        result["command"].append("--review-only")
    if args.context_only:
        result["command"].append("--context-only")
    if args.post_auth_only:
        result["command"].append("--post-auth-only")
    if args.post_auth_review_only:
        result["command"].append("--post-auth-review-only")
    writer = EvidenceWriter(output, result)
    try:
        wheels, result["source"]["wheel_sha256"] = verified_wheels(
            args.harness, PRODUCT
        )
    except RuntimeError as error:
        result.update(status="blocked", error=str(error))
        writer.publish()
        return 2
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
                state["fixture_token"] = secrets.token_urlsafe(32)
                data["fixture_source"] = (
                    ROOT / "tests/atrium_n05/admission_fixture.py"
                ).read_text()
                data["fixture_inputs"] = {
                    "master": data["environment"]["LITELLM_MASTER_KEY"],
                    "fixture_control": state["fixture_token"],
                    "initial_feed_mode": "live"
                    if args.context_only or review or args.protocol_only
                    else "missing",
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
                data["environment"].update(
                    {
                        "PYTHONPATH": RUNTIME + ":" + RUNTIME + "/python",
                        "TMPDIR": RUNTIME,
                        "PYTHONDONTWRITEBYTECODE": "1",
                        "LITELLM_WORKER_STARTUP_HOOKS": "admission_loader:install"
                        if post_auth
                        else "",
                        "ATRIUM_ADMISSION_SETTINGS": RUNTIME
                        + "/admission-settings.json",
                        "N05_OBSERVER_URL": "http://" + self.prefix + "-provider:8000",
                        "N05_OBSERVER_KEY": state["observer_key"],
                        "N05_REVIEW_CLOCK": "1" if review else "0",
                    }
                )
                if args.context_only:
                    # A synthetic global provider is a legacy compatibility twin,
                    # never evidence of owned per-alias/per-domain passthrough.
                    data["environment"].update(
                        {
                            "ANTHROPIC_API_BASE": "http://"
                            + self.prefix
                            + "-provider:8000",
                            "ANTHROPIC_API_KEY": data["environment"][
                                "SYNTHETIC_PROVIDER_KEY"
                            ],
                        }
                    )
                payload = json.dumps(data)
            return super().start(identifier, payload)

        def cleanup(self):
            if state.get("provider_endpoint"):
                try:
                    response = httpx.get(
                        state["provider_endpoint"] + "/_probe/state",
                        headers={"Authorization": "Bearer " + state["observer_key"]},
                        trust_env=False,
                        timeout=5,
                    )
                    observed = response.json()
                    self.result["pre_cleanup_observer"] = {
                        name: observed.get(name)
                        for name in ("installations", "bootstrap_errors", "provider")
                    }
                except Exception:
                    self.result["pre_cleanup_observer"] = {"error": "unavailable"}
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

        def endpoint(self, identifier, port):
            value = super().endpoint(identifier, port)
            if port == 8000:
                state["provider_endpoint"] = value
            return value

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
        evidence["scope"].update(
            {
                "native_only": False,
                "admission_hook": True,
                "post_native_auth_dependency": post_auth,
                "actual_admission_package": True,
                "shared_R04_cache": True,
                "real_R07_feed": True,
                "real_R06_N04_producers": True,
                "full_R06_issuance": False,
                "full_N04_reconciliation": False,
                "workers": 2,
                "output_cache": "native local",
                "protocols": [],
            }
        )
        resources = state["resources"]
        fixture_token = state["fixture_token"]
        helper = httpx.Client(
            base_url=resources.endpoint(state["gateway"], 9010),
            trust_env=False,
            timeout=20,
        )
        try:
            native.wait_http(helper, "/ready", {}, seconds=30)
            if post_auth:
                deadline = time.monotonic() + 30
                while True:
                    response = observer.get("/_probe/state", headers=observer_headers)
                    require(
                        response.status_code == 200, "installation_observer_unavailable"
                    )
                    installed = response.json()["installations"]
                    if len({row["pid"] for row in installed}) == 2:
                        break
                    require(
                        time.monotonic() < deadline, "post_auth_worker_not_installed"
                    )
                    time.sleep(0.1)
                evidence["post_native_auth_installation"] = installed
                checkpoint()

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

            if review:
                from review_cases import run_reviews

                run_reviews(
                    client,
                    observer,
                    observer_headers,
                    action,
                    evidence,
                    run_id,
                    checkpoint,
                )
                return
            if args.post_auth_only:
                from post_auth_cases import run_post_auth
                from protocol_cases import run_protocols

                run_post_auth(
                    client,
                    observer,
                    observer_headers,
                    action,
                    evidence,
                    run_id,
                    checkpoint,
                )
                run_protocols(
                    client,
                    observer,
                    observer_headers,
                    action,
                    evidence,
                    run_id,
                    checkpoint,
                )
                return
            if args.context_only:
                from context_cases import run_contexts
                from protocol_cases import run_protocols

                run_contexts(
                    client,
                    observer,
                    observer_headers,
                    action,
                    evidence,
                    run_id,
                    checkpoint,
                )
                run_protocols(
                    client,
                    observer,
                    observer_headers,
                    action,
                    evidence,
                    run_id,
                    checkpoint,
                )
                return
            if args.protocol_only:
                from protocol_cases import run_protocols

                run_protocols(
                    client,
                    observer,
                    observer_headers,
                    action,
                    evidence,
                    run_id,
                    checkpoint,
                    kinds=(args.protocol_only,),
                )
                return
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
        result["status"] = (
            "partial"
            if any(
                row["status"] != "passed" for row in result.get("protocol_coverage", [])
            )
            or result.get("request_context_gate") == "incomplete"
            or result.get("post_native_auth_gate") == "incomplete"
            else "passed"
        )
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
