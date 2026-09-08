"""Bounded real-native hook/cache/worker placement probe, not a feed adapter."""

import argparse
import hashlib
import json
import logging
import secrets
import signal
import time
from pathlib import Path

import httpx

from supervisor import HARNESS_REVISION, ROOT, git, inventory, load_harness

BOOT_ADDITION = """
import pathlib
hook=pathlib.Path("/run/atrium-n05/admission_hook.py")
hook.write_text(data.pop("probe_hook"))
hook.chmod(0o600)
configuration=pathlib.Path("/run/atrium-n05/config.json")
configuration.write_text(json.dumps(data["config"]))
configuration.chmod(0o600)
"""
MARKER = "fixture-ok-n05"
PATHS = ("/v1/chat/completions", "/chat/completions")


def content(response, stream):
    if not stream:
        return response.json()["choices"][0]["message"]["content"]
    pieces = []
    for line in response.text.splitlines():
        if line.startswith("data: ") and line != "data: [DONE]":
            chunk = json.loads(line[6:])
            for choice in chunk.get("choices", []):
                pieces.append(choice.get("delta", {}).get("content") or "")
    return "".join(pieces)


def exercise(client, observer, control, observer_headers, result, run_id, checkpoint):
    from harness.common import require

    schema = client.get("/openapi.json")
    require(
        schema.status_code == 200 and schema.json()["info"]["version"] == "1.99.1",
        "openapi_version_mismatch",
    )
    exposed = schema.json()["paths"]
    result["native_endpoints"] = {
        path: "post" in exposed.get(path, {})
        for path in (
            *PATHS,
            "/v1/completions",
            "/completions",
            "/v1/embeddings",
            "/embeddings",
            "/v1/responses",
            "/responses",
            "/v1/messages",
            "/messages",
            "/v1/images/generations",
            "/v1/audio/transcriptions",
            "/v1/rerank",
        )
    }
    require(
        all(result["native_endpoints"][path] for path in PATHS), "chat_endpoint_missing"
    )
    generated = client.post(
        "/key/generate",
        headers=control,
        json={
            "duration": "10m",
            "models": ["family-fixture"],
            "allowed_routes": list(PATHS),
            "metadata": {"cc.owner": "command-center", "cc.principal": "fixture-n05"},
        },
    )
    require(generated.status_code == 200, "native_key_fixture_failed")
    raw = generated.json().get("key")
    require(
        isinstance(raw, str) and raw.startswith("sk-"), "native_key_fixture_missing"
    )
    key_hash = hashlib.sha256(raw.encode()).hexdigest()
    native_info = client.get("/key/info", headers=control, params={"key": key_hash})
    require(
        native_info.status_code == 200 and native_info.json()["key"] == key_hash,
        "native_identity_not_verified",
    )
    require(
        native_info.json()["info"]["allowed_routes"] == list(PATHS),
        "native_routes_not_exact",
    )
    result["identity"] = {
        "credential_fingerprint": {
            "algorithm": "sha256",
            "input": "native-key-sha256",
            "digest": hashlib.sha256(key_hash.encode()).hexdigest(),
        },
        "validated_user_api_key_context": True,
        "caller_labels_authoritative": False,
    }

    def state():
        response = observer.get("/_probe/state", headers=observer_headers)
        require(response.status_code == 200, "observer_unavailable")
        return response.json()

    def set_deny(value):
        response = observer.post(
            "/_probe/deny",
            headers=observer_headers,
            json={
                "key_sha256": key_hash,
                "deny": value,
            },
        )
        require(response.status_code == 200, "fixture_deny_control_failed")

    def request(
        path, stream, body, *, token=raw, denied=False, native_auth_failure=False
    ):
        before = state()
        with httpx.Client(
            base_url=str(client.base_url),
            timeout=20,
            follow_redirects=False,
            trust_env=False,
        ) as fresh:
            response = fresh.post(
                path,
                headers={"Authorization": "Bearer " + token, "Connection": "close"},
                json=body,
            )
        after = state()
        events = after["events"][len(before["events"]) :]
        delta = after["provider"]["received"] - before["provider"]["received"]
        if native_auth_failure:
            require(
                response.status_code in (401, 403), "native_authentication_not_denied"
            )
            require(
                not events and delta == 0,
                "native_auth_failure_entered_hook_or_provider",
            )
            return {
                "status": response.status_code,
                "hook_calls": 0,
                "provider_requests": 0,
            }
        require(len(events) == 1, "expected_one_native_pre_call_hook")
        event = events[0]
        require(
            event["key_sha256"] == key_hash
            and event["context_type"] == "UserAPIKeyAuth",
            "hook_did_not_use_native_identity",
        )
        require(
            event["native_principal"] == "fixture-n05",
            "caller_overrode_native_metadata",
        )
        if denied:
            require(
                response.status_code == 403 and "n05_fixture_denied" in response.text,
                "hook_deny_not_before_response",
            )
            require(
                delta == 0
                and MARKER not in response.text
                and not response.headers.get("content-type", "").startswith(
                    "text/event-stream"
                ),
                "denied_request_returned_provider_or_cached_output",
            )
        else:
            require(response.status_code == 200, "native_positive_twin_failed")
            require(
                content(response, stream) == MARKER, "native_positive_content_missing"
            )
        return {
            "status": response.status_code,
            "worker_pid": event["pid"],
            "provider_requests": delta,
            "cached_output": not denied and delta == 0,
            "hook_denied": event["denied"],
            "hook_calls": 1,
            "native_identity_verified": True,
            "stream": stream,
        }

    worker_ids = set()
    for index, (path, stream) in enumerate(
        (path, stream) for path in PATHS for stream in (False, True)
    ):
        case = {
            "id": "n05-chat-" + str(index),
            "path": path,
            "stream": stream,
            "candidate": "CustomLogger.async_pre_call_hook",
            "status": "running",
            "warmup": [],
            "deny": [],
            "recovery": [],
        }
        result["cases"].append(case)
        body = {
            "model": "family-fixture",
            "messages": [
                {"role": "user", "content": f"Synthetic N05 {run_id} protocol {index}"}
            ],
            "stream": stream,
            "max_tokens": 4,
            "temperature": 0,
            "metadata": {"cc.principal": "caller-spoofed", "deny": False},
        }
        set_deny(False)
        case["native_auth_failure"] = request(
            path,
            stream,
            body,
            token="sk-" + secrets.token_urlsafe(32),
            native_auth_failure=True,
        )
        warmed = set()
        for _ in range(40):
            observation = request(path, stream, body)
            case["warmup"].append(observation)
            worker_ids.add(observation["worker_pid"])
            if observation["cached_output"]:
                warmed.add(observation["worker_pid"])
            checkpoint()
            if len(warmed) == 2:
                break
            time.sleep(0.05)
        require(
            len(warmed) == 2 and len(worker_ids) == 2,
            "two_worker_warm_cache_not_observed",
        )
        set_deny(True)
        denied_pids = set()
        for _ in range(30):
            observation = request(path, stream, body, denied=True)
            case["deny"].append(observation)
            denied_pids.add(observation["worker_pid"])
            checkpoint()
            if denied_pids == warmed:
                break
        require(denied_pids == warmed, "deny_not_observed_on_both_warm_workers")
        set_deny(False)
        recovered = set()
        for _ in range(30):
            observation = request(path, stream, body)
            case["recovery"].append(observation)
            require(
                observation["provider_requests"] == 0, "recovery_cache_not_retained"
            )
            recovered.add(observation["worker_pid"])
            if recovered == warmed:
                break
        require(recovered == warmed, "recovery_not_observed_on_both_workers")
        case.update(
            status="passed",
            warm_worker_pids=sorted(warmed),
            no_cached_output_on_deny=True,
        )
        checkpoint()
    result["worker_pids"] = sorted(worker_ids)
    result["provider_counts"] = state()["provider"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    native, shared_hashes = load_harness(args.harness)
    from harness.common import EvidenceWriter, HarnessError, require
    from harness.containers import Resources

    output = args.evidence.resolve()
    require(
        output.is_relative_to(ROOT / "tests/atrium_n05/results"),
        "evidence_path_refused",
    )
    probe_source = ROOT / "tests/atrium_n05"
    source = {
        "component_commit": git(ROOT, "rev-parse", "HEAD").decode().strip(),
        "component_dirty": bool(git(ROOT, "status", "--porcelain").strip()),
        "shared_harness_commit": HARNESS_REVISION,
        "shared_harness_sha256": shared_hashes,
        "owner_spec_sha256": hashlib.sha256(args.spec.read_bytes()).hexdigest(),
        "probe_sha256": {
            p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(probe_source.glob("*.py"))
        },
        "pinned_source": {
            name: {"algorithm": "sha256", "digest": digest}
            for name, digest in json.loads(
                (ROOT / ".artifacts/n05-source-inspection.json").read_text()
            )["source_sha256"].items()
        },
    }
    result = {
        "ticket": "ATR-N05",
        "run_id": "n05-" + secrets.token_hex(8),
        "status": "running",
        "source": source,
        "full_n05": "unimplemented",
        "production_hook_selection": "not-final",
        "fixture_admission": "Authenticated observer deny set keyed only by native UserAPIKeyAuth.api_key",
        "command": [
            "python",
            "tests/atrium_n05/native_runner.py",
            "--harness",
            str(args.harness),
            "--spec",
            str(args.spec),
            "--evidence",
            str(args.evidence),
        ],
    }
    writer = EvidenceWriter(output, result)
    state = {}
    base_boot = native.LITELLM_BOOT
    require(
        '"--num_workers", "1"' in base_boot
        and 'os.environ.update(data["environment"])' in base_boot,
        "unsupported_shared_bootstrap",
    )
    native.LITELLM_BOOT = (
        base_boot.replace('"--num_workers", "1"', '"--num_workers", "2"')
        .replace(
            'os.environ.update(data["environment"])',
            BOOT_ADDITION + '\nos.environ.update(data["environment"])',
        )
        .replace('"/proc/self/fd/" + str(fd)', '"/run/atrium-n05/config.json"')
    )
    base_config = native.configuration

    class ProbeResources(Resources):
        def select_local_engine(self):
            super().select_local_engine()
            state["foreign_before"] = inventory(self)
            self.result["foreign_before"] = state["foreign_before"]
            if any(
                row["state"] == "running" and row["name"] != "ambit-db"
                for row in state["foreign_before"].values()
            ):
                raise RuntimeError("shared_native_vm_busy")

        def create(self, role, image, entrypoint, args, **kwargs):
            if role == "provider":
                args = ["-B", "-c", (probe_source / "provider.py").read_text()]
            if role == "litellm":
                kwargs["options"] = (
                    *kwargs.get("options", ()),
                    "--tmpfs",
                    "/run/atrium-n05:rw,nosuid,nodev,noexec,size=16m,mode=0700",
                )
            return super().create(role, image, entrypoint, args, **kwargs)

        def start(self, identifier, payload=""):
            role = next(
                row["role"]
                for row in self.result["resources"]
                if row.get("id") == identifier
            )
            if role == "provider":
                state["observer"] = json.loads(payload)["observer"]
            if role == "litellm":
                data = json.loads(payload)
                data["probe_hook"] = (probe_source / "admission_hook.py").read_text()
                data["environment"].update(
                    {
                        "N05_OBSERVER_URL": "http://" + self.prefix + "-provider:8000",
                        "N05_OBSERVER_KEY": state["observer"],
                        "PYTHONPATH": "/run/atrium-n05",
                    }
                )
                payload = json.dumps(data)
            return super().start(identifier, payload)

        def cleanup(self):
            super().cleanup()
            after = inventory(self)
            before = state.get("foreign_before", {})
            self.result["foreign_after"] = {key: after.get(key) for key in before}
            require(
                self.result["foreign_after"] == before, "preexisting_resource_changed"
            )
            self.result["foreign_resources_unchanged"] = True
            self.publish()

    def configure(provider):
        config = base_config(provider)
        config["litellm_settings"].update(
            {
                "cache": True,
                "cache_params": {"type": "local", "ttl": 600},
                "callbacks": ["admission_hook.probe"],
            }
        )
        return config

    def callback(*values):
        evidence = values[4]
        evidence["scope"].update(
            {
                "workers": 2,
                "output_cache": "actual LiteLLM local output cache per worker",
                "protocols": [
                    "POST " + path + " (stream=false,true)" for path in PATHS
                ],
                "admission_hook": "fixture-only CustomLogger.async_pre_call_hook",
                "native_auth_modified": False,
                "native_cache_modified": False,
                "full_R04_deny_feed": False,
                "production_hook_selection": "not-final",
            }
        )
        exercise(*values)

    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    for name in ("SIGINT", "SIGTERM"):
        signal.signal(getattr(signal, name), interrupted)
    old_level = logging.root.manager.disable
    logging.disable(logging.CRITICAL)
    native.Resources = ProbeResources
    try:
        native.run(
            result,
            result["run_id"],
            checkpoint=writer.publish,
            exercise_adapter=callback,
            configure=configure,
        )
        result["status"] = "passed"
    except (HarnessError, RuntimeError) as error:
        result.update(
            status="blocked" if str(error) == "shared_native_vm_busy" else "failed",
            error=getattr(
                error,
                "code",
                str(error)
                if str(error) == "shared_native_vm_busy"
                else "probe_runtime_failure",
            ),
        )
    except KeyboardInterrupt:
        result.update(status="interrupted", error="interrupted")
    except Exception:
        result.update(status="failed", error="unexpected_probe_failure")
    finally:
        logging.disable(old_level)
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
