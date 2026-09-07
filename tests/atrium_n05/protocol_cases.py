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
        if not line.startswith("data: ") or line == "data: [DONE]":
            continue
        value = json.loads(line[6:])
        if kind == "responses":
            if value.get("type") == "response.output_text.delta":
                parts.append(value["delta"])
        elif kind == "messages":
            if value.get("type") == "content_block_delta":
                parts.append(value["delta"].get("text", ""))
        else:
            for choice in value.get("choices", []):
                parts.append(
                    choice.get("text", "")
                    if kind == "completions"
                    else choice.get("delta", {}).get("content", "")
                )
    return "".join(parts) == "fixture-ok-n05"


def run_protocols(
    client, observer, observer_headers, action, evidence, run_id, checkpoint
):
    from harness.common import require

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

    def request(path, body, *, expected):
        before = snapshot()
        with httpx.Client(
            base_url=str(client.base_url), trust_env=False, timeout=25
        ) as fresh:
            response = fresh.post(
                path,
                headers={
                    "Authorization": "Bearer " + key["key"],
                    "Connection": "close",
                },
                json=body,
            )
        after = snapshot()
        events = after["events"][len(before["events"]) :]
        delta = after["provider"]["received"] - before["provider"]["received"]
        observation = {
            "status": response.status_code,
            "provider_requests": delta,
            "hook_calls": len(events),
        }
        if events:
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

    for kind in (
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
                try:
                    warmed = set()
                    for _ in range(35):
                        response, observation = request(path, body, expected="permit")
                        row["warmup"].append(observation)
                        require(
                            output_present(response, kind, stream),
                            "protocol_positive_output_unavailable",
                        )
                        require(
                            observation["hook_calls"] == 1,
                            "actual_admission_not_observed",
                        )
                        if observation["provider_requests"] == 0:
                            warmed.add(observation["worker_pid"])
                        if len(warmed) == 2:
                            break
                        time.sleep(0.05)
                    require(len(warmed) == 2, "two_worker_native_cache_not_observed")
                    action("deny", hash=key["hash"])
                    denied = True
                    time.sleep(2)
                    observed = set()
                    for _ in range(30):
                        _, observation = request(path, body, expected="deny")
                        row["denials"].append(observation)
                        require(
                            observation["hook_calls"] == 1, "actual_denial_not_observed"
                        )
                        observed.add(observation["worker_pid"])
                        if observed == warmed:
                            break
                    require(observed == warmed, "both_worker_denials_not_observed")
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
                    if denied:
                        action("deny", hash=key["hash"], value=False)
                        time.sleep(2)
                    checkpoint()
    evidence["full_protocol_gate"] = (
        "passed" if all(row["status"] == "passed" for row in rows) else "incomplete"
    )
