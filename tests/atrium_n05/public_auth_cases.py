"""Real public-route compatibility and opaque-key fail-closed regressions."""

import time

import httpx

from protocol_cases import output_present


def run_public_auth(
    client, observer, control, observer_headers, action, evidence, run_id, checkpoint
):
    from harness.common import require

    rows = evidence.setdefault("native_public_coverage", [])
    evidence["scope"]["protocols"] = [
        "GET /routes (native public, no Atrium initialization)",
        "GET /v1/models (native additional-public/licensing policy)",
        "POST /v1/chat/completions (anonymous and opaque-key permit/deny)",
        "POST /v1/messages/count_tokens (owned refusal and native legacy recovery)",
    ]
    workers = {}
    expected_workers = {row["pid"] for row in evidence["post_native_auth_installation"]}

    def snapshot():
        response = observer.get("/_probe/state", headers=observer_headers)
        require(response.status_code == 200, "native_public_observer_unavailable")
        return response.json()

    def request(connection, method, path, *, headers=None, body=None):
        before = snapshot()
        response = connection.request(method, path, headers=headers, json=body)
        after = snapshot()
        no_key = after["no_key_events"][len(before["no_key_events"]) :]
        keyed = after["auth_events"][len(before["auth_events"]) :]
        controls = after["control_events"][len(before["control_events"]) :]
        events = [*no_key, *keyed, *controls]
        observed = {
            "path": path,
            "status": response.status_code,
            "provider_requests": after["provider"]["received"]
            - before["provider"]["received"],
            "post_auth_calls": len(events),
            "unkeyed_calls": len(no_key),
            "pre_call_calls": len(after["events"]) - len(before["events"]),
            "response_bytes": len(response.content),
        }
        if events:
            require(len(events) == 1, "native_public_duplicate_auth")
            observed["worker_pid"] = events[0]["pid"]
        if no_key:
            require(
                all(
                    "key_sha256" not in event and "jwt_claims" not in event
                    for event in no_key
                ),
                "native_public_identity_telemetry",
            )
            observed["provenance"] = {
                name: no_key[0][name]
                for name in (
                    "via_virtual_key",
                    "token_present",
                    "jwt_claims_present",
                    "admission_initialized",
                    "native_premium",
                    "native_jwt_enabled",
                    "native_public_models",
                )
            }
        evidence["last_native_public_request"] = observed
        checkpoint()
        return response, observed

    def public(connection, expected_pid=None, *, initialized):
        response, observed = request(connection, "GET", "/routes")
        require(
            response.status_code == 200
            and isinstance(response.json().get("routes"), list)
            and observed["unkeyed_calls"] == 1
            and observed["provider_requests"] == 0
            and observed["provenance"]["admission_initialized"] is initialized
            and not observed["provenance"]["via_virtual_key"]
            and not observed["provenance"]["token_present"],
            "native_public_route_not_preserved",
        )
        if expected_pid is not None:
            require(
                observed["worker_pid"] == expected_pid, "native_public_worker_changed"
            )
        return observed

    def denied(response, observed, expected):
        require(
            response.status_code == expected
            and observed["provider_requests"] == 0
            and "fixture-ok-n05" not in response.text
            and not response.headers.get("content-type", "").startswith(
                "text/event-stream"
            ),
            "native_public_denial_failed",
        )

    def record(name, operation):
        row = {"id": name, "status": "running"}
        rows.append(row)
        try:
            operation(row)
            row["status"] = "passed"
        except Exception as error:
            row.update(
                status="blocked",
                error=getattr(
                    error, "code", "native_public_fixture_or_adapter_failure"
                ),
                last_observation=evidence.get("last_native_public_request"),
            )
        checkpoint()
        return row["status"] == "passed"

    require(not action("admission_initialized")["initialized"], "public_state_not_cold")
    try:
        for _ in range(40):
            connection = httpx.Client(
                base_url=str(client.base_url),
                trust_env=False,
                timeout=25,
                limits=httpx.Limits(
                    max_connections=1,
                    max_keepalive_connections=1,
                    keepalive_expiry=None,
                ),
            )
            try:
                observation = public(connection, initialized=False)
                pid = observation["worker_pid"]
                if pid not in workers:
                    workers[pid] = connection
                    connection = None
            finally:
                if connection is not None:
                    connection.close()
            if set(workers) == expected_workers:
                break
            time.sleep(0.1)
        require(set(workers) == expected_workers, "native_public_workers_not_retained")

        record(
            "public-before-admission-initialization",
            lambda row: row.update(
                workers=[
                    public(connection, pid, initialized=False)
                    for pid, connection in workers.items()
                ]
            ),
        )
        require(
            not action("admission_initialized")["initialized"],
            "public_initialized_owned_state",
        )
        provenance = observation["provenance"]
        evidence["native_public_scope"] = {
            "native_premium": provenance["native_premium"],
            "native_jwt_enabled": provenance["native_jwt_enabled"],
            "native_public_models": provenance["native_public_models"],
            "jwt_permit": "not proven: no native premium entitlement"
            if not provenance["native_premium"]
            else "unexecuted; no JWT permit configuration claimed",
            "mapped_jwt_missing_hash": "native SDK provenance-unit negatives, not licensed JWT HTTP proof",
        }

        def additional(row):
            row["workers"] = []
            row["native_public_available"] = provenance["native_public_models"]
            for connection in workers.values():
                response, observed = request(connection, "GET", "/v1/models")
                row["workers"].append(observed)
                if provenance["native_public_models"]:
                    require(
                        response.status_code == 200 and observed["unkeyed_calls"] == 1,
                        "additional_public_not_preserved",
                    )
                else:
                    denied(response, observed, 401)
                    require(
                        observed["post_auth_calls"] == 0,
                        "native_public_license_gate_bypassed",
                    )

        record("additional-public-models-native-license-policy", additional)
        payload = {
            "model": "cc.family.text",
            "max_tokens": 4,
            "messages": [{"role": "user", "content": run_id}],
            "metadata": {
                "api_key": None,
                "token": None,
                "via_virtual_key": False,
                "jwt_claims": {"sub": "forged-admin"},
                "public_route": "/routes",
            },
            "proxy_server_request": {
                "method": "GET",
                "url": "http://forged.invalid/routes",
            },
            "request_route": "/routes",
        }

        def anonymous(row):
            row["workers"] = []
            for connection in workers.values():
                response, observed = request(
                    connection, "POST", "/v1/chat/completions", body=payload
                )
                row["workers"].append(observed)
                denied(response, observed, 401)
                require(
                    observed["post_auth_calls"] == 0,
                    "anonymous_inference_reached_post_auth",
                )

        record("anonymous-protected-inference-remains-native-denied", anonymous)
        if not provenance["native_premium"]:

            def jwt_license(row):
                credential = action("native_jwt_fixture")["jwt"]
                row["workers"] = []
                for connection in workers.values():
                    response, observed = request(
                        connection,
                        "POST",
                        "/v1/chat/completions",
                        headers={"Authorization": "Bearer " + credential},
                        body=payload,
                    )
                    row["workers"].append(observed)
                    denied(response, observed, 403)
                    require(
                        observed["post_auth_calls"] == 0,
                        "native_jwt_license_gate_bypassed",
                    )

            record("native-jwt-license-refusal-not-a-permit", jwt_license)

        require(
            action("initialize_admission")["initialized"],
            "native_public_state_initialization_failed",
        )
        key = action("mint", kind="child")
        legacy = action("mint", kind="legacy")
        headers = {"Authorization": "Bearer " + key["key"]}

        def owned(row):
            row["workers"] = []
            for pid, connection in workers.items():
                response, observed = request(
                    connection,
                    "POST",
                    "/v1/chat/completions",
                    headers=headers,
                    body=payload,
                )
                require(
                    output_present(response, "chat/completions", False),
                    "owned_public_twin_not_permitted",
                )
                require(
                    observed["post_auth_calls"] == 1 and observed["unkeyed_calls"] == 0,
                    "opaque_key_reclassified",
                )
                require(observed["worker_pid"] == pid, "native_public_worker_changed")
                response, denial = request(
                    connection,
                    "POST",
                    "/v1/messages/count_tokens",
                    headers=headers,
                    body=payload,
                )
                denied(response, denial, 403)
                row["workers"].append({"permit": observed, "deny": denial})

        record("owned-key-labels-cannot-fabricate-public-or-jwt-provenance", owned)

        def unknown(row):
            action("producer", producer="resolver", mode="missing")
            try:
                row["workers"] = []
                for pid, connection in workers.items():
                    response, observed = request(
                        connection,
                        "POST",
                        "/v1/chat/completions",
                        headers=headers,
                        body=payload,
                    )
                    denied(response, observed, 503)
                    row["workers"].append(
                        {
                            "managed_deny": observed,
                            "public": public(connection, pid, initialized=True),
                        }
                    )
            finally:
                action("producer", producer="resolver", mode="restore")
            row["recovery"] = []
            for connection in workers.values():
                response, observed = request(
                    connection,
                    "POST",
                    "/v1/messages/count_tokens",
                    headers={"Authorization": "Bearer " + legacy["key"]},
                    body=payload,
                )
                require(
                    response.status_code == 200
                    and response.json() == {"input_tokens": 7},
                    "native_legacy_recovery_failed",
                )
                row["recovery"].append(observed)

        record(
            "missing-managed-state-still-closed-while-public-remains-native", unknown
        )
        evidence["native_public_gate"] = (
            "passed" if all(row["status"] == "passed" for row in rows) else "incomplete"
        )
        checkpoint()
    finally:
        for connection in workers.values():
            connection.close()
