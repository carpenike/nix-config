"""Paired N03 observations through real untrusted-network HTTP/TLS clients."""

import base64
import json
import time


def payload(response):
    body = response.get("body", "")
    if body.startswith("{"):
        return json.loads(body)
    records = [
        json.loads(line[5:].strip())
        for line in body.splitlines()
        if line.startswith("data:")
    ]
    return next(record for record in records if "id" in record)


def execute(f, foundation, client, foundation_address, rows, checkpoint):
    def call(method, url, headers=None, body=None):
        return client.call(
            "request", method=method, url=url, headers=headers or {}, body=body
        )

    def identity(principal="fixture-child", **fields):
        return foundation.call("identity", principal=principal, **fields)["token"]

    def auth(token):
        return {"Authorization": "Bearer " + token}

    def entry(token, instance, domain="family:holt", **fields):
        response = call(
            "POST",
            f["endpoints"]["resolver"] + "/v1/manifests",
            auth(token),
            {"domain": domain, "include_models": False, **fields},
        )
        assert response["status"] == 200, "manifest_not_permitted"
        display = f["generated"]["resolver"]["instances"][instance]["display_name"]
        selected = [
            item
            for item in payload(response)["manifest"]["instances"]
            if item["display_name"] == display
        ]
        assert len(selected) == 1, "unique_fixture_reference_required"
        return selected[0]

    def redeem(token, selected, domain="family:holt", **fields):
        return call(
            "POST",
            f["endpoints"]["resolver"] + "/v1/credentials/redeem",
            auth(token),
            {
                "domain": domain,
                "instance_ref": selected["instance_ref"],
                "auth_ref": selected["auth_ref"],
                **fields,
            },
        )

    def native_credential(token, instance="family-home-child"):
        response = redeem(token, entry(token, instance))
        assert response["status"] == 200, (
            "native_credential_not_delivered_"
            + str(response["status"])
            + "_"
            + payload(response).get("error", {}).get("code", "unknown")
        )
        body = payload(response)
        assert body["credential"]["profile"] == "native-access"
        return body

    def initialize(url, token, extra=None):
        headers = {
            "Accept": "application/json, text/event-stream",
            **auth(token),
            **(extra or {}),
        }
        response = call(
            "POST",
            url,
            headers,
            {
                "jsonrpc": "2.0",
                "id": 0,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "synthetic-n03", "version": "1"},
                },
            },
        )
        assert response["status"] == 200, "native_initialize_failed_" + str(
            response["status"]
        )
        session = response["headers"]["mcp-session-id"]
        call(
            "POST",
            url,
            {**headers, "Mcp-Session-Id": session},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
        )
        return session

    def rpc(url, token, session, method="tools/call", params=None, extra=None):
        return call(
            "POST",
            url,
            {
                "Accept": "application/json, text/event-stream",
                **auth(token),
                "Mcp-Session-Id": session,
                **(extra or {}),
            },
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": method,
                "params": params or {"name": "homelab_list_status"},
            },
        )

    def effects():
        return foundation.call("effects")

    def wait_status(request, expected, seconds=60):
        started = time.monotonic()
        while time.monotonic() - started < seconds:
            response = request()
            if response["status"] == expected:
                return round(time.monotonic() - started, 3)
            time.sleep(1)
        raise AssertionError("native_expected_status_not_observed_" + str(expected))

    def deny(token, issuer, *, remove=False, expected=200):
        encoded = token.split(".")[1]
        identifier = json.loads(
            base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
        )["jti"]
        response = call(
            "DELETE" if remove else "POST",
            f["endpoints"]["resolver"] + "/v1/denies",
            auth(admin),
            {
                "kind": "credential",
                "issuer": issuer,
                "identifier": identifier,
            },
        )
        assert response["status"] == expected, (
            "real_r07_publication_failed_"
            + str(response["status"])
            + "_"
            + payload(response).get("error", {}).get("code", "unknown")
        )
        return response

    def record(name, gates, permits, denials, before=None, after=None):
        if before is not None:
            assert before == after, "denied_request_changed_provider_effects"
        rows.append(
            {
                "case": name,
                "status": "passed",
                "gates": gates,
                "permits": permits,
                "denials": denials,
                "denial_effects_unchanged": before == after
                if before is not None
                else None,
            }
        )
        checkpoint()

    # Healthy native services exist before direct-access refusals are counted.
    for route in ("/healthz", "/.well-known/oauth-authorization-server"):
        assert call("GET", f["endpoints"]["native"] + route)["status"] == 200
    discovery = call(
        "GET", f["endpoints"]["native"] + "/.well-known/oauth-authorization-server"
    )
    assert call("GET", payload(discovery)["jwks_uri"])["status"] == 200
    assert client.call("connect", address=f["frontAddress"], port=f["port"])[
        "connected"
    ]
    denied_ports = []
    for port in (18765, 18766, f["nativePolicyPort"], 13417, f["port"]):
        assert not client.call("connect", address=foundation_address, port=port)[
            "connected"
        ]
        denied_ports.append(port)
    record(
        "native-discovery-and-backend-socket-boundary",
        ["T4"],
        [200],
        [{"backend_ports": denied_ports}],
    )

    child, admin = identity(), identity("ryan")
    own = native_credential(child)
    url, token = own["target"], own["credential"]["token"]
    session = initialize(url, token)
    assert rpc(url, token, session)["status"] == 200
    before = effects()
    missing = call(
        "POST", url, body={"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
    )
    wrong_purpose = call(
        "POST",
        url,
        {**auth(child), "Accept": "application/json, text/event-stream"},
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    )
    assert missing["status"] == wrong_purpose["status"] == 401
    record(
        "native-caddy-permit-missing-and-wrong-purpose",
        ["T1", "T26"],
        [200],
        [401, 401],
        before,
        effects(),
    )

    adult = native_credential(admin, "family-home-adults")
    before = effects()
    cross = rpc(adult["target"], token, session)
    assert cross["status"] == 401
    record(
        "cross-view-at-the-public-native-edge",
        ["T1", "T26"],
        [],
        [401],
        before,
        effects(),
    )
    adult_session = initialize(adult["target"], adult["credential"]["token"])
    assert (
        rpc(adult["target"], adult["credential"]["token"], adult_session)["status"]
        == 200
    )
    rows[-1]["permits"] = [200]

    foreign_ref = entry(child, "family-home-child")
    issued = foundation.call("native-state")["issued"]
    assert redeem(admin, foreign_ref)["status"] == 403
    assert foundation.call("native-state")["issued"] == issued
    assert redeem(child, foreign_ref)["status"] == 200
    record("foreign-principal-reference-cannot-mint", ["T26"], [200], [403])

    before = effects()
    issued = foundation.call("native-state")["issued"]
    spoof = {
        **auth(token),
        "X-SSL-Client-Verify": "SUCCESS",
        "X-Forwarded-Client-Cert": "forged",
        "X-Client-Cert": "forged",
        "X-Principal": "ryan",
        "X-Admin": "true",
        "X-Forwarded-For": "203.0.113.77",
    }
    for path in ("/cc/issue", "/cc/issue/", "/cc/%69ssue"):
        rejected = call(
            "POST",
            f["endpoints"]["native"] + path,
            spoof,
            {"principal": "ryan", "view_id": "family-home-public"},
        )
        assert rejected["status"] == 404
    assert foundation.call("native-state")["issued"] == issued
    assert rpc(url, token, session, extra=spoof)["status"] == 200
    observed = foundation.call("observed-headers")
    assert observed["identity_assertion_headers"] == []
    assert observed["forwarded_for"] != "203.0.113.77"
    assert observed["forwarded_proto"] == "https"
    assert observed["forwarded_host"] == f["names"]["native"] + ":" + str(f["port"])
    assert observed["upstream_host"] == "127.0.0.1:" + str(f["port"])
    record(
        "public-issuance-and-forged-peer-labels", ["T4", "T26"], [200], [404, 404, 404]
    )
    assert effects()["read"] == before["read"] + 1

    foundation.call("native-peer", wrong=True)
    issued = foundation.call("native-state")["issued"]
    rejected = redeem(child, entry(child, "family-home-child"))
    assert (
        rejected["status"] == 503
        and foundation.call("native-state")["issued"] == issued
    )
    foundation.call("native-peer", wrong=False)
    assert redeem(child, entry(child, "family-home-child"))["status"] == 200
    record("real-native-resolver-peer-refusal-and-recovery", ["T26"], [200], [503])

    # Retained public OAuth uses the actual native callback and the private C8 service.
    public_url = f["endpoints"]["native"] + "/mcp"
    granted = client.call(
        "native-oauth",
        operation="login",
        principal="fixture-child",
        scope="fixture.read",
        overrides={
            "principal": "ryan",
            "subject": "synthetic-ryan-subject",
            "authority": "foreign-authority",
            "view_id": "family-home-admin",
        },
    )
    assert granted["status"] == 200, "native_public_oauth_not_permitted"
    public_tokens = payload(granted)
    public_session = initialize(public_url, public_tokens["access_token"])
    before = effects()
    assert (
        rpc(public_url, public_tokens["access_token"], public_session)["status"] == 200
    )
    assert effects()["read"] == before["read"] + 1
    references = f["generated"]["resolver"]["catalogs"]["home-mcp-fixture"]["scopes"][
        "fixture.read"
    ]["resources"]
    assert references, "source_derived_read_resource_required"
    before = effects()
    resource = rpc(
        public_url,
        public_tokens["access_token"],
        public_session,
        "resources/read",
        {"uri": references[0]},
    )
    assert resource["status"] == 200, "native_public_resource_not_permitted"
    resource_body = payload(resource)
    assert "error" not in resource_body, "native_public_resource_rpc_error"
    assert [
        item.get("text") for item in resource_body.get("result", {}).get("contents", [])
    ] == ["Synthetic resource data"], "native_public_resource_contents_required"
    assert effects()["resource"] == before["resource"] + 1
    before = effects()
    denied_tool = rpc(
        public_url,
        public_tokens["access_token"],
        public_session,
        params={"name": "ha_call_service", "arguments": {}},
    )
    assert denied_tool["status"] == 403
    foreign = rpc(adult["target"], public_tokens["access_token"], public_session)
    assert foreign["status"] == 401
    record(
        "actual-public-native-oauth-c8-read-resource-and-scope-boundary",
        ["T1", "T7", "T10", "T26"],
        [200, 200],
        [403, 401],
        before,
        effects(),
    )
    renewed = client.call(
        "native-oauth",
        operation="refresh",
        client_id=granted["client_id"],
        refresh_token=public_tokens["refresh_token"],
    )
    assert renewed["status"] == 200, "native_public_refresh_not_permitted"
    refreshed = payload(renewed)
    assert rpc(public_url, refreshed["access_token"], public_session)["status"] == 200
    before = effects()
    widened = client.call(
        "native-oauth",
        operation="refresh",
        client_id=granted["client_id"],
        refresh_token=refreshed["refresh_token"],
        scope="admin fixture.read",
    )
    assert widened["status"] == 400
    record(
        "actual-native-current-policy-refresh-cannot-widen",
        ["T10", "T18"],
        [200],
        [400],
        before,
        effects(),
    )

    before = effects()
    before_policy = foundation.call("policy-state")["counts"]
    private_denials = []
    for route in (
        "/v1/native-policy",
        "/v1/native-policy/",
        "/v1/%6eative-policy",
    ):
        for public_origin in (f["endpoints"]["resolver"], f["endpoints"]["native"]):
            response = call("POST", public_origin + route, {**spoof, **auth(admin)}, {})
            assert response["status"] == 404
            private_denials.append(404)
    for mode in ("missing-peer", "wrong-peer", "audience", "authority", "view"):
        response = foundation.call("policy-probe", mode=mode)
        assert response["status"] == (0 if mode == "missing-peer" else 403)
        private_denials.append(response["status"])
    assert foundation.call("policy-state")["counts"] == before_policy
    record(
        "private-native-policy-service-and-route-boundaries",
        ["T4", "T26"],
        [200],
        private_denials,
        before,
        effects(),
    )

    foundation.call("policy-peer", wrong=True)
    before_native = foundation.call("native-state")["public_access"]
    before_policy = foundation.call("policy-state")["counts"]
    wrong_service = client.call(
        "native-oauth",
        operation="login",
        principal="fixture-child",
        scope="fixture.read",
    )
    assert wrong_service["status"] == 400
    assert foundation.call("native-state")["public_access"] == before_native
    assert foundation.call("policy-state")["counts"] == before_policy
    foundation.call("policy-peer", wrong=False)
    recovered = client.call(
        "native-oauth",
        operation="login",
        principal="fixture-child",
        scope="fixture.read",
    )
    assert recovered["status"] == 200
    recovered_tokens = payload(recovered)
    current_session = initialize(public_url, recovered_tokens["access_token"])
    assert (
        rpc(public_url, recovered_tokens["access_token"], current_session)["status"]
        == 200
    )
    record(
        "actual-native-policy-client-mtls-refusal-and-recovery",
        ["T26"],
        [200],
        [400],
    )
    assert foundation.call("policy-outage", enabled=True)["changed"]
    before = effects()
    assert (
        rpc(public_url, recovered_tokens["access_token"], current_session)["status"]
        == 503
    )
    denied_after = effects()
    assert denied_after == before
    assert foundation.call("policy-outage", enabled=False)["changed"]
    wait_status(
        lambda: rpc(public_url, recovered_tokens["access_token"], current_session),
        200,
        seconds=15,
    )
    record(
        "required-private-native-policy-outage-and-recovery",
        ["T20"],
        [200],
        [503],
        before,
        denied_after,
    )

    short_group = client.call(
        "native-oauth",
        operation="login",
        principal="fixture-child",
        scope="fixture.read",
        lifetime=8,
    )
    assert short_group["status"] == 200
    short_group_tokens = payload(short_group)
    short_group_session = initialize(public_url, short_group_tokens["access_token"])
    assert (
        rpc(public_url, short_group_tokens["access_token"], short_group_session)[
            "status"
        ]
        == 200
    )
    deadlines = foundation.call("policy-state")["group_deadlines"]
    assert deadlines, "verified_native_group_observation_missing"
    encoded = short_group_tokens["access_token"].split(".")[1]
    native_expiry = json.loads(
        base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
    )["exp"]
    assert native_expiry <= min(deadlines)
    time.sleep(max(0, min(deadlines) - time.time()) + 0.2)
    before = effects()
    expired_group_refresh = client.call(
        "native-oauth",
        operation="refresh",
        client_id=short_group["client_id"],
        refresh_token=short_group_tokens["refresh_token"],
    )
    assert expired_group_refresh["status"] == 400
    assert foundation.call("policy-state")["group_deadlines"] == deadlines
    record(
        "actual-native-group-observation-bound-is-not-renewed",
        ["T10", "T26"],
        [200],
        [400],
        before,
        effects(),
    )

    # Both earlier SDK sessions were process-local and cannot survive the native restart.
    # Native callbacks also supplied newer genuine group observations; old upstream
    # access tokens cannot overwrite those watermarks in later resolver probes.
    child, admin = identity(), identity("ryan")
    session = initialize(url, token)
    adult_session = initialize(adult["target"], adult["credential"]["token"])

    registration_url = f"https://{f['names']['registration']}:{f['registrationPort']}/v1/devices/register"
    missing_peer = call("POST", registration_url, spoof, {"local_available": []})
    assert missing_peer["status"] == 0, "registration_must_require_a_real_tls_peer"
    assert client.call("device", operation="initialize")["completed"]
    assert client.call("device", operation="enroll", authorization=admin)["completed"]
    assert client.call("device", operation="register")["completed"]
    assert (
        call(
            "POST",
            f["endpoints"]["resolver"] + "/v1/devices/register",
            spoof,
            {"local_available": []},
        )["status"]
        == 404
    )
    record(
        "actual-sidecar-enrollment-and-tls-preserving-registration",
        ["T8", "T26"],
        [200],
        ["tls-peer-required", 404],
    )

    challenge = call(
        "POST",
        f["endpoints"]["resolver"] + "/v1/devices/challenges",
        auth(admin),
        {"instance_ids": ["family-home-child"]},
    )
    assert challenge["status"] == 201
    proof = client.call("device", operation="proof", challenge=payload(challenge))
    completed = call(
        "POST",
        f["endpoints"]["resolver"] + "/v1/devices/challenges/complete",
        auth(admin),
        proof,
    )
    assert completed["status"] == 200
    assert (
        call(
            "POST",
            f["endpoints"]["resolver"] + "/v1/devices/challenges/complete",
            auth(admin),
            proof,
        )["status"]
        == 409
    )
    evidence = payload(completed)["device_evidence"]
    device_ref = entry(admin, "family-home-child", device_evidence=evidence)
    assert (
        redeem(admin, device_ref, device_evidence="ryan-mac-fixture")["status"] == 403
    )
    device_response = redeem(admin, device_ref, device_evidence=evidence)
    assert device_response["status"] == 200
    device = payload(device_response)
    device_session = initialize(device["target"], device["credential"]["token"])
    assert (
        rpc(device["target"], device["credential"]["token"], device_session)["status"]
        == 200
    )
    assert (
        call(
            "DELETE",
            f["endpoints"]["resolver"] + "/v1/devices/ryan-mac-fixture",
            auth(admin),
        )["status"]
        == 204
    )
    propagation = wait_status(
        lambda: rpc(device["target"], device["credential"]["token"], device_session),
        403,
    )
    before = effects()
    assert (
        rpc(device["target"], device["credential"]["token"], device_session)["status"]
        == 403
    )
    record(
        "real-device-proof-replay-and-native-device-denial",
        ["T15", "T26"],
        [200],
        [409, 403, 403],
        before,
        effects(),
    )
    rows[-1]["healthy_propagation_seconds"] = propagation

    companion = redeem(
        admin, entry(admin, "personal-whiskey", "personal:ryan"), "personal:ryan"
    )
    assert companion["status"] == 200
    credential = payload(companion)["credential"]
    assert credential["profile"] == "whiskey-companion"
    whiskey_url = f["endpoints"]["whiskey"] + "/cc/mcp"
    method = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
    missing = call(
        "POST",
        whiskey_url,
        {**auth(admin), "Accept": "application/json, text/event-stream"},
        method,
    )
    assert missing["status"] == 401
    allowed = call(
        "POST",
        whiskey_url,
        {
            **auth(admin),
            "X-Atrium-Grant": credential["token"],
            "Accept": "application/json, text/event-stream",
        },
        method,
    )
    assert allowed["status"] == 200
    legacy = call(
        "POST",
        f["endpoints"]["whiskey"] + "/api/mcp",
        {**auth(admin), "Accept": "application/json, text/event-stream"},
        method,
    )
    assert legacy["status"] == 200
    record(
        "real-companion-and-retained-native-whiskey-route",
        ["T1", "T26"],
        [200, 200],
        [401],
    )

    deny(credential["token"], f["endpoints"]["resolver"])
    whiskey_headers = {
        **auth(admin),
        "X-Atrium-Grant": credential["token"],
        "Accept": "application/json, text/event-stream",
    }
    propagation = wait_status(
        lambda: call("POST", whiskey_url, whiskey_headers, method), 403
    )
    before = effects()
    assert call("POST", whiskey_url, whiskey_headers, method)["status"] == 403
    assert (
        call(
            "POST",
            f["endpoints"]["whiskey"] + "/api/mcp",
            {**auth(admin), "Accept": "application/json, text/event-stream"},
            method,
        )["status"]
        == 200
    )
    record(
        "real-r07-whiskey-known-deny-keeps-native-legacy",
        ["T15", "T26"],
        [200],
        [403],
        before,
        effects(),
    )
    rows[-1]["healthy_propagation_seconds"] = propagation
    deny(credential["token"], f["endpoints"]["resolver"], remove=True)
    wait_status(lambda: call("POST", whiskey_url, whiskey_headers, method), 200)

    short = native_credential(identity(lifetime=8))
    short_session = initialize(short["target"], short["credential"]["token"])
    assert (
        rpc(short["target"], short["credential"]["token"], short_session)["status"]
        == 200
    )
    time.sleep(max(0, short["credential"]["expires_at"] - time.time()) + 0.2)
    before = effects()
    assert (
        rpc(short["target"], short["credential"]["token"], short_session)["status"]
        == 401
    )
    record(
        "actual-native-expiry-not-a-cache-or-proxy-exemption",
        ["T26"],
        [200],
        [401],
        before,
        effects(),
    )

    # Real elapsed time, not a patched clock or a fabricated stale publication.
    denied_admin = native_credential(admin)
    denied_native_session = initialize(
        denied_admin["target"], denied_admin["credential"]["token"]
    )
    assert (
        rpc(
            denied_admin["target"],
            denied_admin["credential"]["token"],
            denied_native_session,
        )["status"]
        == 200
    )
    deny(denied_admin["credential"]["token"], f["endpoints"]["native"])
    native_jti_propagation = wait_status(
        lambda: rpc(
            denied_admin["target"],
            denied_admin["credential"]["token"],
            denied_native_session,
        ),
        403,
    )
    before = effects()
    assert (
        rpc(
            denied_admin["target"],
            denied_admin["credential"]["token"],
            denied_native_session,
        )["status"]
        == 403
    )
    after = effects()
    deny(denied_admin["credential"]["token"], f["endpoints"]["native"], remove=True)
    wait_status(
        lambda: rpc(
            denied_admin["target"],
            denied_admin["credential"]["token"],
            denied_native_session,
        ),
        200,
    )
    record(
        "actual-r05-native-jti-r07-denial-and-recovery",
        ["T15", "T26"],
        [200, 200],
        [403],
        before,
        after,
    )
    rows[-1]["healthy_propagation_seconds"] = native_jti_propagation
    # The long-lived identity remains valid, but a newer assertion follows the short-expiry probe.
    child = identity()
    ordinary = native_credential(child)
    ordinary_session = initialize(ordinary["target"], ordinary["credential"]["token"])
    privileged = native_credential(admin)
    privileged_session = initialize(
        privileged["target"], privileged["credential"]["token"]
    )
    assert (
        rpc(ordinary["target"], ordinary["credential"]["token"], ordinary_session)[
            "status"
        ]
        == 200
    )
    assert (
        rpc(
            privileged["target"], privileged["credential"]["token"], privileged_session
        )["status"]
        == 200
    )
    deny(credential["token"], f["endpoints"]["resolver"])
    wait_status(lambda: call("POST", whiskey_url, whiskey_headers, method), 403)
    fresh_companion = payload(
        redeem(
            admin, entry(admin, "personal-whiskey", "personal:ryan"), "personal:ryan"
        )
    )["credential"]["token"]
    initial_alerts = foundation.call("native-state")["alerts"]
    fault = foundation.call("feed-outage", enabled=True)
    assert fault.get("changed"), "feed_fault_not_installed_" + fault.get(
        "code", "unknown"
    )
    checkpoint()
    started = time.monotonic()
    time.sleep(310)
    before = effects()
    ordinary_status = rpc(
        ordinary["target"], ordinary["credential"]["token"], ordinary_session
    )["status"]
    known_status = call("POST", whiskey_url, whiskey_headers, method)["status"]
    assert ordinary_status == 503 and known_status == 403
    after = effects()
    assert (
        rpc(
            privileged["target"], privileged["credential"]["token"], privileged_session
        )["status"]
        == 200
    )
    assert (
        call(
            "POST",
            whiskey_url,
            {
                **auth(admin),
                "X-Atrium-Grant": fresh_companion,
                "Accept": "application/json, text/event-stream",
            },
            method,
        )["status"]
        == 200
    )
    assert foundation.call("native-state")["alerts"] > initial_alerts
    record(
        "real-feed-outage-mcp-refusal-whiskey-known-deny-and-admin-alert",
        ["T15", "T20"],
        [200, 200],
        [503, 403],
        before,
        after,
    )
    rows[-1]["elapsed_outage_seconds"] = round(time.monotonic() - started, 3)
    foundation.call("feed-outage", enabled=False)
    wait_status(
        lambda: rpc(
            ordinary["target"], ordinary["credential"]["token"], ordinary_session
        ),
        200,
    )
    record("real-native-feed-recovery", ["T20"], [200], [503])

    if not f["modelPlaneReady"]:
        unavailable = call(
            "POST",
            f["endpoints"]["resolver"] + "/v1/manifests",
            auth(admin),
            {"domain": "personal:ryan", "include_models": True},
        )
        assert unavailable["status"] == 503
        assert call("GET", f["endpoints"]["models"] + "/v1/models")["status"] == 503
        rows.append(
            {
                "case": "model-plane-explicitly-blocked",
                "status": "blocked",
                "reason": f["modelPlaneBlocker"],
                "observed": [503, 503],
            }
        )
    return rows
