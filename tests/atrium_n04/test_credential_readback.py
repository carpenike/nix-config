import copy
import json
import secrets
from contextlib import nullcontext
from types import SimpleNamespace

import pytest

from atrium_litellm import native as native_module
from atrium_litellm.controller import Controller
from atrium_litellm.errors import ControllerError
from atrium_litellm.native import Native, NativeError


@pytest.fixture
def clock(monkeypatch):
    value = SimpleNamespace(now=0.0, sleeps=[])

    def sleep(seconds):
        value.sleeps.append(seconds)
        value.now += seconds

    monkeypatch.setattr(
        native_module,
        "time",
        SimpleNamespace(monotonic=lambda: value.now, sleep=sleep),
    )
    return value


@pytest.fixture
def native():
    return Native("http://gateway.atrium.invalid", "sk-" + secrets.token_urlsafe(32))


def test_current_exact_credential_needs_no_retry(native, clock, monkeypatch):
    calls = []
    expected = {"cc.account": "fixture"}

    def credentials(*, timeout):
        calls.append(timeout)
        return {"cc.fixture": {"credential_info": expected}}

    monkeypatch.setattr(native, "credentials", credentials)
    native.wait_for_credential("cc.fixture", expected)
    assert calls == [native_module.CREDENTIAL_READBACK_SECONDS]
    assert clock.sleeps == []


def test_missing_and_stale_worker_values_require_exact_convergence(
    native, clock, monkeypatch
):
    expected = {"cc.account": "fixture"}
    responses = iter(
        [
            {},
            {"cc.fixture": {"credential_info": {"cc.account": "older"}}},
            {"cc.fixture": {"credential_info": expected}},
        ]
    )
    timeouts = []

    def credentials(*, timeout):
        timeouts.append(timeout)
        return next(responses)

    monkeypatch.setattr(native, "credentials", credentials)
    native.wait_for_credential("cc.fixture", expected)
    assert timeouts == [65.0, 64.5, 64.0]
    assert clock.sleeps == [0.5, 0.5]


def test_readback_returns_snapshot_without_combining_different_workers(
    native,
    clock,
    monkeypatch,
):
    expected = {"cc.first": {"cc.account": "one"}, "cc.second": {"cc.account": "two"}}
    complete = {key: {"credential_info": info} for key, info in expected.items()}
    responses = iter(
        [
            {"cc.first": complete["cc.first"]},
            {"cc.second": complete["cc.second"]},
            complete,
        ]
    )
    monkeypatch.setattr(native, "credentials", lambda **_: next(responses))
    actual = native.wait_for_credentials(expected, deadline=65.0)
    assert actual is complete
    assert clock.sleeps == [0.5, 0.5]


def test_supplied_deadline_cannot_restart_the_readback_budget(
    native, clock, monkeypatch
):
    clock.now = 64.0
    timeouts = []

    def credentials(*, timeout):
        timeouts.append(timeout)
        return {}

    monkeypatch.setattr(native, "credentials", credentials)
    with pytest.raises(ControllerError, match="native_credential_not_applied"):
        native.wait_for_credential("cc.fixture", {}, deadline=65.0)
    assert clock.now == 65.0 and timeouts == [1.0, 0.5]


@pytest.mark.parametrize(
    ("response", "error"),
    [
        ({}, "owned_credential_missing"),
        ({"cc.owned": {"credential_info": {}}}, "native_account_binding_drift"),
    ],
)
def test_owned_binding_failure_is_not_retried_while_waiting_for_a_new_credential(
    native,
    clock,
    monkeypatch,
    response,
    error,
):
    calls = []

    def credentials(*, timeout):
        calls.append(timeout)
        return response

    monkeypatch.setattr(native, "credentials", credentials)
    with pytest.raises(ControllerError, match=error):
        native.wait_for_credentials(
            {"cc.new": {"cc.account": "fixture"}},
            deadline=65.0,
            owned={"cc.owned": {"cc.account": "fixture"}},
        )
    assert calls == [65.0] and clock.sleeps == []


@pytest.mark.parametrize("response", [{}, {"cc.fixture": {"credential_info": {}}}])
def test_missing_or_different_metadata_still_fails_at_deadline(
    native, clock, monkeypatch, response
):
    calls = []

    def credentials(*, timeout):
        calls.append(timeout)
        return response

    monkeypatch.setattr(native, "credentials", credentials)
    with pytest.raises(ControllerError, match="native_credential_not_applied"):
        native.wait_for_credential("cc.fixture", {"cc.account": "fixture"})
    assert clock.now == native_module.CREDENTIAL_READBACK_SECONDS
    assert all(
        0 < timeout <= native_module.CREDENTIAL_READBACK_SECONDS for timeout in calls
    )


def test_matching_response_after_deadline_cannot_report_success(
    native, clock, monkeypatch
):
    expected = {"cc.account": "fixture"}

    def credentials(*, timeout):
        clock.now += timeout
        return {"cc.fixture": {"credential_info": expected}}

    monkeypatch.setattr(native, "credentials", credentials)
    with pytest.raises(ControllerError, match="native_credential_not_applied"):
        native.wait_for_credential("cc.fixture", expected)
    assert clock.sleeps == []


@pytest.mark.parametrize(
    "failure",
    [
        NativeError(401),
        NativeError(403),
        ControllerError("incomplete_native_credentials"),
    ],
)
def test_authentication_and_malformed_readback_errors_do_not_retry(
    native, clock, monkeypatch, failure
):
    calls = []

    def credentials(*, timeout):
        calls.append(timeout)
        raise failure

    monkeypatch.setattr(native, "credentials", credentials)
    with pytest.raises(type(failure)) as observed:
        native.wait_for_credential("cc.fixture", {"cc.account": "fixture"})
    assert observed.value is failure
    assert len(calls) == 1 and clock.sleeps == []


@pytest.mark.parametrize(("remaining", "applied"), [(0.25, 0.25), (50.0, 20)])
def test_native_read_is_bounded_by_remaining_and_transport_timeout(
    native, monkeypatch, remaining, applied
):
    calls = []

    def open_request(request, *, timeout):
        calls.append((request.get_method(), request.full_url, timeout))
        return nullcontext(
            SimpleNamespace(
                status=200,
                read=lambda _limit: json.dumps(
                    {"success": True, "credentials": []}
                ).encode(),
            )
        )

    monkeypatch.setattr(native.opener, "open", open_request)
    assert native.credentials(timeout=remaining) == {}
    assert calls == [("GET", "http://gateway.atrium.invalid/credentials", applied)]


@pytest.mark.parametrize("timeout", [0, -1, True, float("nan"), float("inf")])
def test_invalid_native_timeout_is_rejected_before_io(native, monkeypatch, timeout):
    def unexpected(*_args, **_kwargs):
        raise AssertionError("network must not be reached")

    monkeypatch.setattr(native.opener, "open", unexpected)
    with pytest.raises(ControllerError, match="invalid_native_request_timeout"):
        native.credentials(timeout=timeout)


@pytest.mark.parametrize("converges", [True, False])
def test_controller_does_not_repeat_post_or_publish_ownership_early(
    native, clock, monkeypatch, converges
):
    expected = {"cc.account": "fixture"}
    calls = []
    reads = []
    saves = []
    ledger = SimpleNamespace(state={"credentials": {}})
    ledger.save = lambda: saves.append(copy.deepcopy(ledger.state))
    controller = object.__new__(Controller)
    controller.ledger = ledger
    controller.native = native
    controller.desired = SimpleNamespace(
        document={"service_credentials": {"logical": {}}}
    )
    controller.credential_reader = lambda *_: secrets.token_urlsafe(32)

    def call(method, path, body):
        calls.append((method, path))
        return {"success": True}

    def credentials(*, timeout):
        reads.append(timeout)
        if converges and len(reads) > 1:
            return {"cc.fixture": {"credential_info": expected}}
        return {}

    monkeypatch.setattr(native, "call", call)
    monkeypatch.setattr(native, "credentials", credentials)
    action = {
        "action": "create-credential",
        "logical": "logical",
        "record": {
            "native_id": "cc.fixture",
            "expected": expected,
            "status": "pending",
        },
    }
    if converges:
        controller._apply_infrastructure(action)
        assert saves[-1]["credentials"]["logical"]["status"] == "owned"
    else:
        with pytest.raises(ControllerError, match="native_credential_not_applied"):
            controller._apply_infrastructure(action)
        assert ledger.state["credentials"]["logical"]["status"] == "pending"
        assert len(saves) == 1
    assert calls == [("POST", "/credentials")]
    assert saves[0]["credentials"]["logical"]["status"] == "pending"
