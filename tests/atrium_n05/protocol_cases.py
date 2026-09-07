"""Explicit native protocol observations; failed/unexecuted paths never become passes."""

import json
import time

import httpx


def output_present(response, kind, stream):
    if response.status_code != 200:
        return False
    if kind == "embeddings":
        data = response.json().get("data")
        return isinstance(data, list) and bool(data) and bool(data[0].get("embedding"))
    if not stream:
        body = response.json()
        if kind == "completions":
            return body["choices"][0]["text"] == "fixture-ok-n05"
        if kind == "responses":
            return any(
                part.get("text") == "fixture-ok-n05"
                for item in body.get("output", [])
                for part in item.get("content", [])
            )
        if kind == "messages":
            return any(
                part.get("text") == "fixture-ok-n05" for part in body.get("content", [])
            )
        return body["choices"][0]["message"]["content"] == "fixture-ok-n05"
    parts = []
    for line in response.text.splitlines():
        if not line.startswith("data:"):
            continue
        encoded = line[5:].strip()
        if encoded == "[DONE]":
            continue
        value = json.loads(encoded)
        if (
            not isinstance(value, dict)
            or value.get("error") is not None
            or value.get("type") in ("error", "response.failed", "response.incomplete")
        ):
            return False
        if kind == "responses":
            if value.get("type") == "response.output_text.delta":
                parts.append(value["delta"])
        elif kind == "messages":
            if value.get("type") == "content_block_delta":
                parts.append(value["delta"].get("text", ""))
        else:
            for choice in value.get("choices", []):
                text = (
                    choice.get("text", choice.get("delta", {}).get("content", ""))
                    if kind == "completions"
                    else choice.get("delta", {}).get("content", "")
                )
                if text is not None:
                    if not isinstance(text, str):
                        return False
                    parts.append(text)
    return "".join(parts) == "fixture-ok-n05"


def run_protocols(
    client, observer, observer_headers, action, evidence, run_id, checkpoint, kinds=None
):
    from harness.common import require

    post_auth = evidence["scope"].get("post_native_auth_dependency", False)
    schema = client.get("/openapi.json")
    require(schema.status_code == 200, "native_openapi_unavailable")
    advertised = schema.json()["paths"]
    evidence["advertised_api_inventory"] = {
        path: sorted(
            method
            for method in methods
            if method.lower() in {"get", "post", "put", "patch", "delete"}
        )
        for path, methods in advertised.items()
    }
    rows = evidence.setdefault("protocol_coverage", [])

    def snapshot():
        response = observer.get("/_probe/state", headers=observer_headers)
        require(response.status_code == 200, "observer_unavailable")
        return response.json()

    def connection():
        return httpx.Client(
            base_url=str(client.base_url),
            trust_env=False,
            timeout=25,
            limits=httpx.Limits(
                max_connections=1, max_keepalive_connections=1, keepalive_expiry=None
            ),
        )

    def request(path, body, *, expected, worker=None):
        before = snapshot()
        fresh = worker or connection()
        try:
            response = fresh.post(
                path,
                headers={
                    "Authorization": "Bearer " + key["key"],
                    "Connection": "keep-alive" if worker else "close",
                },
                json=body,
            )
        finally:
            if worker is None:
                fresh.close()
        after = snapshot()
        events = after["events"][len(before["events"]) :]
        authenticated = after["auth_events"][len(before["auth_events"]) :]
        delta = after["provider"]["received"] - before["provider"]["received"]
        observation = {
            "status": response.status_code,
            "provider_requests": delta,
            "hook_calls": len(events),
            "post_auth_calls": len(authenticated),
            "response_bytes": len(response.content),
            "content_type": response.headers.get("content-type", ""),
        }
        observation["provider_protocols"] = after["provider"].get("protocols", [])[
            len(before["provider"].get("protocols", [])) :
        ]
        if response.status_code == 200 and body.get("stream"):
            shapes = set()
            for line in response.text.splitlines():
                if line.startswith("data:") and line[5:].strip() != "[DONE]":
                    chunk = json.loads(line[5:].strip())
                    for choice in chunk.get("choices", []):
                        shapes.add(",".join(sorted(choice)))
            observation["native_stream_choice_fields"] = sorted(shapes)
        if authenticated:
            observation["worker_pid"] = authenticated[-1]["pid"]
            observation["post_auth_status"] = authenticated[-1]["status"]
        if events:
            if post_auth:
                require(
                    authenticated and events[-1]["pid"] == authenticated[-1]["pid"],
                    "native_admission_worker_changed",
                )
            else:
                observation["worker_pid"] = events[-1]["pid"]
        if expected == "deny":
            require(
                response.status_code == 403
                and delta == 0
                and "fixture-ok-n05" not in response.text
                and not response.headers.get("content-type", "").startswith(
                    "text/event-stream"
                ),
                "owned_protocol_denial_failed",
            )
        return response, observation

    for kind in kinds or (
        "chat/completions",
        "completions",
        "embeddings",
        "responses",
        "messages",
    ):
        for prefix in ("", "/v1"):
            path = prefix + "/" + kind
            for stream in (False,) if kind == "embeddings" else (False, True):
                key = action("mint", kind="child")
                row = {
                    "path": path,
                    "stream": stream,
                    "status": "running",
                    "warmup": [],
                    "denials": [],
                }
                rows.append(row)
                marker = f"{run_id}-{kind}-{prefix}-{stream}"
                body = {
                    "model": key["model"],
                    "metadata": {"principal": "forged-admin", "native_owned": False},
                }
                if kind == "embeddings":
                    body["input"] = marker
                elif kind == "completions":
                    body.update(prompt=marker, stream=stream, max_tokens=4)
                elif kind == "responses":
                    body.update(input=marker, stream=stream, max_output_tokens=4)
                else:
                    body.update(
                        messages=[{"role": "user", "content": marker}],
                        stream=stream,
                        max_tokens=4,
                    )
                if path not in advertised:
                    response, observation = request(path, body, expected="absent")
                    row.update(status="native-route-unavailable", refusal=observation)
                    require(
                        response.status_code in (403, 404)
                        and observation["provider_requests"] == 0,
                        "unavailable_native_route_not_refused",
                    )
                    checkpoint()
                    continue
                denied = False
                connections = {}
                try:
                    # Keep a real TCP connection to each observed worker so warm
                    # and denied requests do not depend on repeated accept fairness.
                    for _ in range(35):
                        candidate = connection()
                        try:
                            response, observation = request(
                                path, body, expected="permit", worker=candidate
                            )
                            pid = observation.get("worker_pid")
                            require(type(pid) is int, "native_worker_identity_missing")
                            if pid not in connections:
                                connections[pid] = candidate
                        finally:
                            if candidate not in connections.values():
                                candidate.close()
                        row["warmup"].append(observation)
                        require(
                            output_present(response, kind, stream),
                            "protocol_positive_output_unavailable",
                        )
                        require(
                            observation["hook_calls"] == 1
                            and observation["post_auth_calls"] == int(post_auth),
                            "actual_admission_not_observed",
                        )
                        if len(connections) == 2:
                            break
                        time.sleep(0.1)
                    require(len(connections) == 2, "two_native_workers_not_observed")
                    warmed = set()
                    for pid, worker in connections.items():
                        for _ in range(5):
                            response, observation = request(
                                path, body, expected="permit", worker=worker
                            )
                            row["warmup"].append(observation)
                            require(
                                observation["worker_pid"] == pid,
                                "native_worker_connection_changed",
                            )
                            require(
                                output_present(response, kind, stream)
                                and observation["hook_calls"] == 1
                                and observation["post_auth_calls"] == int(post_auth),
                                "protocol_worker_positive_missing",
                            )
                            if observation["provider_requests"] == 0:
                                warmed.add(pid)
                                break
                            time.sleep(0.05)
                    require(len(warmed) == 2, "two_worker_native_cache_not_observed")
                    row["warm_worker_pids"] = sorted(warmed)
                    action("deny", hash=key["hash"])
                    denied = True
                    time.sleep(2)
                    observed = set()
                    for pid, worker in connections.items():
                        _, observation = request(
                            path, body, expected="deny", worker=worker
                        )
                        row["denials"].append(observation)
                        require(
                            observation["worker_pid"] == pid,
                            "native_worker_connection_changed",
                        )
                        require(
                            observation["hook_calls"] == int(not post_auth)
                            and observation["post_auth_calls"] == int(post_auth)
                            and (
                                not post_auth or observation["post_auth_status"] == 403
                            ),
                            "actual_post_auth_denial_not_observed",
                        )
                        observed.add(observation["worker_pid"])
                    require(observed == warmed, "both_worker_denials_not_observed")
                    action("deny", hash=key["hash"], value=False)
                    denied = False
                    time.sleep(2)
                    row["recovery"] = []
                    for pid, worker in connections.items():
                        response, observation = request(
                            path, body, expected="permit", worker=worker
                        )
                        row["recovery"].append(observation)
                        require(
                            observation["worker_pid"] == pid
                            and output_present(response, kind, stream)
                            and observation["provider_requests"] == 0
                            and observation["hook_calls"] == 1
                            and observation["post_auth_calls"] == int(post_auth),
                            "both_worker_cache_recovery_missing",
                        )
                    row.update(
                        status="passed",
                        warm_worker_pids=sorted(warmed),
                        zero_denied_effects=True,
                    )
                except Exception as error:
                    row.update(
                        status="blocked",
                        error=getattr(
                            error, "code", "protocol_fixture_or_adapter_failure"
                        ),
                    )
                finally:
                    try:
                        if denied:
                            action("deny", hash=key["hash"], value=False)
                            time.sleep(2)
                    finally:
                        for worker in connections.values():
                            worker.close()
                        checkpoint()
    evidence["full_protocol_gate"] = (
        "passed" if all(row["status"] == "passed" for row in rows) else "incomplete"
    )
    evidence["scope"]["protocols"] = [
        f"POST {row['path']} ({'streaming' if row['stream'] else 'non-streaming'})"
        for row in rows
    ]
