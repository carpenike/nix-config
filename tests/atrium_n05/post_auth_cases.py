"""Paired native token-count and post-authentication admission regressions."""

import base64
import secrets
import time

import httpx

from protocol_cases import output_present

COUNT_PATH = "/v1/messages/count_tokens"
CHAT_PATH = "/v1/chat/completions"


def run_post_auth(
    client, observer, observer_headers, action, evidence, run_id, checkpoint
):
    from harness.common import require

    rows = evidence.setdefault("post_native_auth_coverage", [])
    evidence["source"]["native_context"] = action("context_source")
    installed = evidence["post_native_auth_installation"]
    workers = {row["pid"] for row in installed}
    require(
        len(workers) == 2
        and all(COUNT_PATH in row["dependency_paths"]["request"] for row in installed),
        "token_count_boundary_not_installed",
    )
    evidence["post_native_auth_scope"] = {
        "boundary": "FastAPI overrides delegate to original HTTP/WebSocket native auth before admission",
        "installed_before_first_inference": sorted(workers),
        "native_auth_and_authorization": "unmodified originals, including security dependencies",
        "token_count_legacy": "real native router and authenticated provider counter, not tokenizer fallback",
        "manual_auth_calls": "not intercepted by dependency overrides; no expanded coverage claim",
        "legacy_websocket_provider_positive": "unexecuted",
    }

    def snapshot():
        response = observer.get("/_probe/state", headers=observer_headers)
        require(response.status_code == 200, "post_auth_observer_unavailable")
        return response.json()

    def body(key, suffix=""):
        return {
            "model": key["model"],
            "messages": [{"role": "user", "content": run_id + "-post-auth-" + suffix}],
            "max_tokens": 4,
            "metadata": {
                "principal": "forged-admin",
                "native_owned": False,
                "admin_outage_eligible": True,
            },
            "proxy_server_request": {
                "method": "POST",
                "url": "http://forged.invalid/v1/chat/completions",
            },
            "request_route": CHAT_PATH,
        }

    def request(key, path, payload=None, *, websocket=False):
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
                "GET" if websocket else "POST",
                path,
                headers=headers,
                json=None if websocket else payload,
                params={"model": key["model"]} if websocket else None,
            )
        after = snapshot()
        authenticated = after["auth_events"][len(before["auth_events"]) :]
        pre_call = after["events"][len(before["events"]) :]
        observation = {
            "path": path,
            "status": response.status_code,
            "post_auth_calls": len(authenticated),
            "pre_call_calls": len(pre_call),
            "provider_requests": after["provider"]["received"]
            - before["provider"]["received"],
            "authorized_provider_requests": after["provider"]["authorized"]
            - before["provider"]["authorized"],
            "provider_paths": after["provider"]["requests"][
                len(before["provider"]["requests"]) :
            ],
            "response_bytes": len(response.content),
            "content_type": response.headers.get("content-type", ""),
        }
        if authenticated:
            event = authenticated[-1]
            require(event["key_sha256"] == key["hash"], "native_identity_hash_changed")
            observation.update(
                worker_pid=event["pid"],
                post_auth_status=event["status"],
                native_route=event["native_request_route"],
                transport=event["transport"],
            )
        evidence["last_post_auth_request"] = observation
        checkpoint()
        return response, observation

    def both(key, path, payload, *, expected, warm=False, websocket=False):
        observations, seen = [], set()
        for _ in range(35):
            response, observed = request(key, path, payload, websocket=websocket)
            observations.append(observed)
            require(
                response.status_code == expected, "post_auth_native_status_mismatch"
            )
            require(observed["post_auth_calls"] == 1, "post_auth_boundary_not_observed")
            require(
                observed["pre_call_calls"]
                == (1 if expected == 200 and path == CHAT_PATH else 0),
                "unexpected_pre_call_boundary",
            )
            if expected != 200:
                require(
                    observed["provider_requests"] == 0
                    and "fixture-ok-n05" not in response.text
                    and "input_tokens" not in response.text
                    and not observed["content_type"].startswith("text/event-stream"),
                    "post_auth_denied_effect",
                )
            elif path == COUNT_PATH:
                require(
                    response.json() == {"input_tokens": 7},
                    "native_legacy_token_count_missing",
                )
                require(
                    observed["provider_requests"]
                    == observed["authorized_provider_requests"]
                    and observed["provider_requests"] in (0, 1),
                    "legacy_token_count_not_native_provider",
                )
            else:
                require(
                    output_present(response, "chat/completions", False),
                    "post_auth_positive_missing",
                )
            if not warm or observed["provider_requests"] == 0:
                seen.add(observed["worker_pid"])
            if seen == workers:
                return observations
            time.sleep(0.1)
        require(False, "post_auth_both_workers_not_observed")

    def record(identifier, operation):
        row = {"id": identifier, "status": "running"}
        rows.append(row)
        try:
            operation(row)
            row["status"] = "passed"
        except Exception as error:
            row.update(
                status="blocked",
                error=getattr(error, "code", "post_auth_fixture_or_adapter_failure"),
                last_observation=evidence.get("last_post_auth_request"),
            )
        checkpoint()
        return row["status"] == "passed"

    keys = {
        kind: action("mint", kind=kind)
        for kind in ("child", "admin", "service", "legacy")
    }

    def cold(row):
        for kind, key in keys.items():
            path = COUNT_PATH if kind == "legacy" else CHAT_PATH
            row[kind] = both(
                key,
                path,
                body(key, "cold"),
                expected=200 if kind in ("admin", "legacy") else 403,
            )
        require(
            any(alert["reason"] == "missing" for alert in action("status")["alerts"]),
            "native_cold_admin_alert_missing",
        )

    record("cold-post-auth-admin-only-freshness", cold)
    action("feed", mode="live")
    time.sleep(2)
    legacy = keys["legacy"]
    record(
        "native-legacy-token-count",
        lambda row: row.update(
            permit=both(legacy, COUNT_PATH, body(legacy, "count"), expected=200)
        ),
    )

    for kind in ("child", "admin", "service"):
        key = keys[kind]
        payload = body(key, "count")

        def owned(row):
            row["warm_inference"] = both(
                key, CHAT_PATH, payload, expected=200, warm=True
            )
            row["owned_count_refused"] = both(key, COUNT_PATH, payload, expected=403)
            action("native_failure", value=True)
            action("deny", hash=key["hash"])
            try:
                row["pending_native_revocations"] = action("drain")["pending"]
                require(
                    row["pending_native_revocations"] > 0, "native_failure_not_pending"
                )
                time.sleep(2)
                row["warm_inference_after_deny"] = both(
                    key, CHAT_PATH, payload, expected=403
                )
                row["count_after_same_deny"] = both(
                    key, COUNT_PATH, payload, expected=403
                )
                row["legacy_twin"] = both(
                    legacy, COUNT_PATH, body(legacy, "count"), expected=200
                )
            finally:
                action("deny", hash=key["hash"], value=False)
                action("native_failure", value=False)
                time.sleep(2)

        if not record("owned-token-count-" + kind, owned):
            evidence["post_native_auth_scope"]["remaining_owned_templates"] = (
                "unexecuted after boundary failure"
            )
            break

    def invalid(row):
        invalid_key = {
            "key": "sk-" + secrets.token_urlsafe(32),
            "model": legacy["model"],
            "hash": "",
        }
        response, observation = request(invalid_key, COUNT_PATH, body(legacy))
        row["native_refusal"] = observation
        require(
            response.status_code == 401
            and observation["post_auth_calls"]
            == observation["pre_call_calls"]
            == observation["provider_requests"]
            == 0,
            "original_native_authentication_not_preserved",
        )

    record("native-invalid-key-before-post-auth", invalid)

    def missing(row):
        action("producer", producer="resolver", mode="missing")
        try:
            row["deny"] = both(legacy, COUNT_PATH, body(legacy), expected=503)
        finally:
            action("producer", producer="resolver", mode="restore")
        row["recovery"] = both(legacy, COUNT_PATH, body(legacy), expected=200)

    record("token-count-unknown-ownership-closed", missing)

    def websocket(row):
        key = action("mint", kind="child")
        row["deny_before_accept"] = both(
            key, "/v1/responses", None, expected=403, websocket=True
        )

    record("owned-websocket-after-original-auth", websocket)

    def stale(row):
        fresh = {
            kind: action("mint", kind=kind)
            for kind in ("child", "admin", "service", "legacy")
        }
        action("feed", mode="signed-stale", age=301)
        try:
            time.sleep(2)
            for kind, key in fresh.items():
                path = COUNT_PATH if kind == "legacy" else CHAT_PATH
                row[kind] = both(
                    key,
                    path,
                    body(key, "stale"),
                    expected=200 if kind in ("admin", "legacy") else 403,
                )
            require(
                any(alert["reason"] == "stale" for alert in action("status")["alerts"]),
                "native_stale_admin_alert_missing",
            )
            action("feed", mode="signed-stale", age=301, principals=["fixture-admin"])
            time.sleep(2)
            row["known_admin_deny"] = both(
                fresh["admin"], CHAT_PATH, body(fresh["admin"], "stale"), expected=403
            )
        finally:
            action("feed", mode="live")
            time.sleep(2)

    record("stale-post-auth-admin-only-freshness", stale)
    counts = snapshot()["provider"]
    require(
        any(row["path"] == "/v1/responses/input_tokens" for row in counts["protocols"]),
        "authenticated_native_token_count_not_observed",
    )
    evidence["post_native_auth_gate"] = (
        "passed" if all(row["status"] == "passed" for row in rows) else "incomplete"
    )
    checkpoint()
