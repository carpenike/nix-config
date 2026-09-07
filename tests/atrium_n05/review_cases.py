"""Real native ACL and authentication-rejection clock regressions."""

import time

import httpx


def run_reviews(
    client, observer, observer_headers, action, evidence, run_id, checkpoint
):
    from harness.common import require

    evidence["scope"].update(
        {
            "background_poller": False,
            "clock_fixture": "Native auth datetime and adapter time inputs only; no host/VM clock change",
            "protocols": ["POST /v1/chat/completions non-streaming"],
        }
    )

    def snapshot(path="/_probe/state"):
        response = observer.get(path, headers=observer_headers)
        require(response.status_code == 200, "review_observer_unavailable")
        return response.json()

    def request(key, expected=200):
        before = snapshot()
        with httpx.Client(
            base_url=str(client.base_url), trust_env=False, timeout=25
        ) as connection:
            response = connection.post(
                "/v1/chat/completions",
                headers={
                    "Authorization": "Bearer " + key["key"],
                    "Connection": "close",
                },
                json={
                    "model": key["model"],
                    "max_tokens": 4,
                    "messages": [{"role": "user", "content": run_id + key["hash"]}],
                },
            )
        after = snapshot()
        events = after["events"][len(before["events"]) :]
        delta = after["provider"]["received"] - before["provider"]["received"]
        observed = {
            "status": response.status_code,
            "provider_requests": delta,
            "admission_calls": len(events),
            "worker_pid": events[-1]["pid"] if events else None,
        }
        evidence["last_review_request"] = observed
        checkpoint()
        require(response.status_code == expected, "native_review_status_mismatch")
        if expected == 200:
            require(
                response.json()["choices"][0]["message"]["content"] == "fixture-ok-n05",
                "native_review_positive_missing",
            )
        else:
            require(
                delta == 0 and "fixture-ok-n05" not in response.text,
                "native_review_denied_effect",
            )
        require(
            len(events) == (0 if expected == 401 else 1), "native_review_hook_boundary"
        )
        return observed

    child = action("mint", kind="child")
    permit = request(child)
    action("policy", mode="exclude-child")
    denied, workers = [], set()
    for _ in range(40):
        observed = request(child, 403)
        denied.append(observed)
        workers.add(observed["worker_pid"])
        if len(workers) == 2:
            break
    require(len(workers) == 2, "acl_revocation_not_seen_by_both_workers")
    action("policy", mode="restore")
    evidence["cases"].append(
        {
            "id": "current-acl-removal",
            "status": "passed",
            "permit": permit,
            "deny": denied,
            "recovery": request(child),
            "worker_pids": sorted(workers),
        }
    )
    checkpoint()

    expiring = action("mint", kind="admin", native_seconds=5)
    permit = request(expiring)
    before = action("status")["last_now"]
    require(before < expiring["expires_at"], "clock_fixture_key_expired_before_permit")
    time.sleep(max(0, expiring["expires_at"] + 1 - time.time()))
    threshold = int(time.time())
    offset = len(snapshot("/_probe/clocks"))
    denied, workers = [], set()
    for _ in range(40):
        denied.append(request(expiring, 401))
        clocks = [
            row
            for row in snapshot("/_probe/clocks")[offset:]
            if row["key_sha256"] == expiring["hash"]
        ]
        require(
            clocks and all(row["last_now"] >= threshold for row in clocks),
            "native_auth_failure_did_not_observe_clock",
        )
        workers.update(row["pid"] for row in clocks)
        if len(workers) == 2:
            break
    require(len(workers) == 2, "native_auth_failure_clock_worker_missing")
    recorded = action("status")["last_now"]
    action("clock", now=before)
    rollback, seen = [], set()
    try:
        for _ in range(40):
            observed = request(expiring, 403)
            rollback.append(observed)
            seen.add(observed["worker_pid"])
            if seen == workers:
                break
        require(seen == workers, "rollback_not_denied_by_both_workers")
        require(action("status")["last_now"] >= recorded, "durable_clock_rolled_back")
    finally:
        action("clock", now=None)
    evidence["cases"].append(
        {
            "id": "native-auth-expiry-clock-rollback",
            "status": "passed",
            "permit": permit,
            "native_expiry": denied,
            "after_rollback": rollback,
            "recorded_highwater": recorded,
            "rollback_clock": before,
            "recovery": request(action("mint", kind="admin")),
            "worker_pids": sorted(workers),
        }
    )
    checkpoint()
