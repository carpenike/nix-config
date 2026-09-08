"""Bounded route/context proof against native authentication and the actual adapter."""

import base64
import secrets
import time

import httpx

from protocol_cases import output_present


def disabled_routes(model):
    for prefix in ("", "/v1"):
        for suffix in (
            "images/generations",
            "images/edits",
            "audio/speech",
            "audio/transcriptions",
            "rerank",
            "moderations",
            "realtime/calls",
            "realtime/client_secrets",
        ):
            yield "POST", prefix + "/" + suffix, False
        yield "GET", prefix + "/realtime", True
    yield "POST", "/v2/rerank", False
    for prefix in ("/engines/" + model, "/openai/deployments/" + model):
        for suffix in ("chat/completions", "completions", "embeddings"):
            yield "POST", prefix + "/" + suffix, False
    for suffix in ("images/generations", "images/edits"):
        yield "POST", "/openai/deployments/" + model + "/" + suffix, False
    yield "POST", "/openai/v1/responses", False
    yield "GET", "/openai/v1/realtime", True
    for prefix in ("", "/v1beta"):
        for suffix in ("generateContent", "streamGenerateContent"):
            yield "POST", prefix + "/models/" + model + ":" + suffix, False
    yield "POST", "/v1/messages/count_tokens", False
    yield "POST", "/v1/responses/compact", False


def run_contexts(
    client, observer, observer_headers, action, evidence, run_id, checkpoint
):
    from harness.common import require

    post_auth = evidence["scope"].get("post_native_auth_dependency", False)
    rows = evidence.setdefault("request_context_coverage", [])
    evidence["source"]["native_context"] = action("context_source")
    evidence["request_context_scope"] = {
        "native_auth_router_cache_and_admission": "actual pinned 1.99.1",
        "normal_protocols": "separately enumerated in protocol_coverage",
        "raw_passthrough": "verified non-owned legacy only; no owned alias/domain permit claim",
        "native_route_drift": "isolated native /key/update; protected producer routes unchanged",
        "disabled_routes": "bounded explicit requests, not a complete OpenAPI audit",
        "legacy_websocket_positive": "unexecuted; only native owned handshake refusal tested",
    }
    keys = {
        kind: action("mint", kind=kind)
        for kind in ("child", "admin", "service", "legacy")
    }

    def snapshot():
        response = observer.get("/_probe/state", headers=observer_headers)
        require(response.status_code == 200, "observer_unavailable")
        return response.json()

    def request(key, method, path, body=None, *, websocket=False):
        before = snapshot()
        headers = {"Authorization": "Bearer " + key["key"], "Connection": "close"}
        if websocket:
            headers.update(
                {
                    "Connection": "Upgrade",
                    "Upgrade": "websocket",
                    "Sec-WebSocket-Version": "13",
                    "Sec-WebSocket-Key": base64.b64encode(
                        secrets.token_bytes(16)
                    ).decode(),
                }
            )
        with httpx.Client(
            base_url=str(client.base_url), trust_env=False, timeout=25
        ) as fresh:
            response = fresh.request(
                method,
                path,
                headers=headers,
                json=None if websocket else body,
                params={"model": key["model"]} if websocket else None,
            )
        after = snapshot()
        events = after["events"][len(before["events"]) :]
        authenticated = after["auth_events"][len(before["auth_events"]) :]
        observation = {
            "status": response.status_code,
            "provider_requests": after["provider"]["received"]
            - before["provider"]["received"],
            "provider_paths": after["provider"]["requests"][
                len(before["provider"]["requests"]) :
            ],
            "hook_calls": len(events),
            "post_auth_calls": len(authenticated),
            "post_auth_events": [
                {
                    name: event[name]
                    for name in ("pid", "status", "native_request_route", "transport")
                }
                for event in authenticated
            ],
            "response_bytes": len(response.content),
            "content_type": response.headers.get("content-type", ""),
            "output_present": "fixture-ok-n05" in response.text,
            "events": [
                {
                    name: event[name]
                    for name in (
                        "pid",
                        "status",
                        "call_type",
                        "native_request_route",
                        "has_proxy_server_request",
                    )
                }
                for event in events
            ],
        }
        return response, observation

    def denied(response, observation, status=403):
        require(
            response.status_code == status
            and observation["provider_requests"] == 0
            and not observation["output_present"]
            and not observation["content_type"].startswith("text/event-stream"),
            "owned_context_denial_failed",
        )

    def both_workers(row, key, method, path, body, *, permit=False, kind="messages"):
        workers = set()
        for _ in range(30):
            response, observation = request(key, method, path, body)
            row.setdefault("observations", []).append(observation)
            boundary = (
                observation["post_auth_events"] if post_auth else observation["events"]
            )
            require(len(boundary) == 1, "context_admission_not_observed")
            event = boundary[0]
            require(
                event["native_request_route"] == path, "native_route_context_mismatch"
            )
            if path.startswith("/anthropic/") and (permit or not post_auth):
                require(observation["hook_calls"] == 1, "legacy_pre_call_not_observed")
                pre_call = observation["events"][0]
                require(
                    pre_call["call_type"] == "pass_through_endpoint"
                    and pre_call["has_proxy_server_request"]
                    == (isinstance(body, dict) and "proxy_server_request" in body),
                    "raw_callback_shape_not_observed",
                )
            if permit:
                valid = (
                    response.status_code == 200
                    and response.json().get("data", [{}])[0].get("id")
                    == "fixture-legacy"
                    if method == "GET"
                    else output_present(response, kind, body.get("stream", False))
                )
                require(valid, "legacy_native_positive_unavailable")
                if path.startswith("/anthropic/"):
                    require(
                        observation["provider_requests"] == 1,
                        "raw_provider_not_observed",
                    )
            else:
                denied(response, observation)
                require(
                    observation["hook_calls"] == int(not post_auth),
                    "owned_denial_boundary_mismatch",
                )
            workers.add(event["pid"])
            if len(workers) == 2:
                row["worker_pids"] = sorted(workers)
                return
            time.sleep(0.1)
        require(False, "both_context_workers_not_observed")

    def body(key, stream=False, forged=False):
        value = {
            "model": key["model"],
            "max_tokens": 4,
            "stream": stream,
            "messages": [{"role": "user", "content": run_id + "-context"}],
        }
        if forged:
            value.update(
                {
                    "proxy_server_request": {
                        "method": "POST",
                        "url": "http://forged.invalid/v1/chat/completions",
                    },
                    "request_route": "/v1/chat/completions",
                    "call_type": "acompletion",
                    "metadata": {
                        "principal": "forged-admin",
                        "native_owned": False,
                        "admin_outage_eligible": True,
                    },
                }
            )
        return value

    def record(row, operation):
        rows.append(row | {"status": "running"})
        row = rows[-1]
        try:
            operation(row)
            row["status"] = "passed"
        except Exception as error:
            row.update(
                status="blocked",
                error=getattr(
                    error, "code", "native_context_fixture_or_adapter_failure"
                ),
            )
        checkpoint()
        return row["status"] == "passed"

    for kind in ("child", "admin", "service"):
        key = keys[kind]
        forged = body(key, forged=True)
        forged["proxy_server_request"]["url"] = "http://forged.invalid/key/generate"
        forged["proxy_server_request"]["method"] = "GET"
        record(
            {"id": "native-route-not-body-" + kind},
            lambda row: both_workers(
                row,
                key,
                "POST",
                "/v1/chat/completions",
                forged,
                permit=True,
                kind="chat/completions",
            ),
        )

        def native_refusal(row):
            response, observation = request(
                key, "POST", "/anthropic/v1/messages", body(key, forged=True)
            )
            row["observation"] = observation
            denied(response, observation)
            require(
                observation["hook_calls"] == 0, "default_raw_route_not_native_refusal"
            )

        record({"id": "raw-template-native-refusal-" + kind}, native_refusal)

    keys = {
        kind: action("mint", kind=kind)
        for kind in ("child", "admin", "service", "legacy")
    }
    for key in keys.values():
        drift = action("native_raw_routes", hash=key["hash"])
        require(drift["protected_routes_unchanged"], "protected_fixture_routes_changed")
        evidence["request_context_scope"]["protected_template_routes"] = drift[
            "protected_routes"
        ]

    record(
        {
            "id": "legacy-no-model-no-common-transport",
            "path": "/anthropic/v1/models",
        },
        lambda row: both_workers(
            row, keys["legacy"], "GET", "/anthropic/v1/models", None, permit=True
        ),
    )

    raw_failed = False
    for kind in ("child", "admin", "service", "legacy"):
        for stream in (False, True):
            for forged in (False, True):
                if raw_failed:
                    break
                key = keys[kind]
                ok = record(
                    {
                        "id": "raw-passthrough-" + kind,
                        "path": "/anthropic/v1/messages",
                        "stream": stream,
                        "forged_context": forged,
                        "owned_expected": "refused"
                        if kind != "legacy"
                        else "outside-Atrium",
                    },
                    lambda row: both_workers(
                        row,
                        key,
                        "POST",
                        "/anthropic/v1/messages",
                        body(key, stream, forged),
                        permit=kind == "legacy",
                    ),
                )
                if not ok:
                    raw_failed = True
                    evidence["request_context_scope"]["raw_remaining_rows"] = (
                        "unexecuted after first boundary failure"
                    )

    if not raw_failed:

        def ownership_unavailable(row):
            action("producer", producer="resolver", mode="missing")
            try:
                response, observation = request(
                    keys["legacy"], "GET", "/anthropic/v1/models"
                )
                row["deny"] = observation
                denied(response, observation, 503)
            finally:
                action("producer", producer="resolver", mode="restore")
            both_workers(
                row, keys["legacy"], "GET", "/anthropic/v1/models", None, permit=True
            )

        record({"id": "raw-missing-ownership-not-legacy"}, ownership_unavailable)

    evidence["legacy_context_gate"] = (
        "passed" if all(row["status"] == "passed" for row in rows) else "incomplete"
    )

    for method, path, websocket in disabled_routes(keys["child"]["model"]):

        def disabled(row):
            for kind in ("child", "admin", "service"):
                key = keys[kind]
                actual_path = path.replace(keys["child"]["model"], key["model"])
                response, observation = request(
                    key, method, actual_path, body(key), websocket=websocket
                )
                row.setdefault("templates", {})[kind] = observation
                require(
                    response.status_code in (401, 403),
                    "disabled_owned_route_not_refused",
                )
                denied(response, observation, response.status_code)

        record(
            {
                "id": "disabled-owned-route",
                "method": method,
                "path": path,
                "websocket_handshake": websocket,
            },
            disabled,
        )

    def token_count_known_deny(row):
        key = action("mint", kind="child")
        payload = body(key)
        payload["messages"][0]["content"] += "-token-count-deny"
        response, observation = request(key, "POST", "/v1/chat/completions", payload)
        row["permit"] = observation
        require(
            output_present(response, "chat/completions", False),
            "token_counter_permit_twin_failed",
        )
        action("native_failure", value=True)
        action("deny", hash=key["hash"])
        try:
            pending = action("drain")
            require(pending["pending"] > 0, "native_revoke_failure_not_pending")
            row["native_revocation_pending"] = True
            time.sleep(2)
            response, observation = request(
                key, "POST", "/v1/chat/completions", payload
            )
            row["ordinary_signed_deny"] = observation
            denied(response, observation)
            response, observation = request(
                key, "POST", "/v1/messages/count_tokens", payload
            )
            row["token_count_after_same_deny"] = observation
            denied(response, observation)
        finally:
            action("deny", hash=key["hash"], value=False)
            action("native_failure", value=False)
            time.sleep(2)

    record(
        {"id": "token-count-known-deny", "path": "/v1/messages/count_tokens"},
        token_count_known_deny,
    )

    evidence["request_context_gate"] = (
        "passed" if all(row["status"] == "passed" for row in rows) else "incomplete"
    )
    checkpoint()
