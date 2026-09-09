import asyncio
import copy
import hashlib
import json
import re
import secrets
import stat
import subprocess
import sys

import pytest

from atrium_litellm.errors import ControllerError
from atrium_litellm.native import Native
from readback_diagnostic import (
    BOOT,
    PUBLIC_NATIVE_REVISION,
    ROOT,
    classify,
    configuration,
    management_identity,
)
from readback_observer import ObservedResponses, PID_HEADER


def test_native_boot_uses_private_config_reopenable_by_spawned_workers(tmp_path):
    wrapper = """
import io,json,os,sys
boot=sys.stdin.read()
root=sys.argv[1]
sys.argv=["-c",root]
sys.stdin=io.StringIO(json.dumps({"observer":"", "environment":{},
 "config":{"model_list":[]}, "workers":2}))
os.execv=lambda executable,arguments: print(json.dumps(arguments))
exec(compile(boot,"native-readback-bootstrap","exec"))
"""
    prepared = subprocess.run(
        [sys.executable, "-I", "-c", wrapper, str(tmp_path)],
        input=BOOT,
        text=True,
        capture_output=True,
        check=True,
        timeout=10,
    )
    arguments = json.loads(prepared.stdout)
    path = tmp_path / "gateway.json"
    assert arguments[arguments.index("--config") + 1] == str(path)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    reopened = subprocess.run(
        [
            sys.executable,
            "-I",
            "-c",
            "import json,sys; assert json.load(open(sys.argv[1])) == {'model_list': []}",
            str(path),
        ],
        close_fds=True,
        capture_output=True,
        check=True,
        timeout=10,
    )
    assert reopened.returncode == 0


def test_native_source_pins_retain_explicit_sha256_fingerprints():
    pins = json.loads(
        (ROOT / "tests/atrium_n04/readback-source-pins.json").read_bytes()
    )
    assert pins["revision"] == PUBLIC_NATIVE_REVISION
    assert pins["package_version"] == "1.99.1"
    assert len(pins["files"]) == 5
    for value in pins["files"].values():
        assert value["algorithm"] == "sha256"
        assert re.fullmatch("[0-9a-f]{64}", value["digest"])


def test_control_key_verification_uses_bootstrap_not_its_own_identity(monkeypatch):
    master = "sk-" + secrets.token_urlsafe(32)
    control = "sk-" + secrets.token_urlsafe(32)
    control_id = hashlib.sha256(control.encode()).hexdigest()
    calls = []

    def call(native, method, path, *, query):
        calls.append((native.management_id, method, path, query))
        return {
            "key": control_id,
            "info": {
                "allowed_routes": ["/credentials"],
                "user_id": "n03-controller-control",
            },
        }

    monkeypatch.setattr(Native, "call", call)
    result = management_identity(
        "http://gateway.atrium.invalid", master, control, ["/credentials"], []
    )
    assert calls == [
        (
            hashlib.sha256(master.encode()).hexdigest(),
            "GET",
            "/key/info",
            {"key": control_id},
        )
    ]
    assert result["master_used_for_control_verification"]
    assert not result["master_used_for_credential_readback"]


def test_native_comparison_distinguishes_missing_mismatched_and_exact_metadata():
    expected = {"cc.installation": "synthetic", "cc.account": "fixture"}
    missing = classify({"success": True, "credentials": []}, "cc.fixture", expected)
    mismatch = classify(
        {
            "success": True,
            "credentials": [
                {
                    "credential_name": "cc.fixture",
                    "credential_info": {"different": True},
                }
            ],
        },
        "cc.fixture",
        expected,
    )
    matching = classify(
        {
            "success": True,
            "credentials": [
                {"credential_name": "cc.fixture", "credential_info": expected}
            ],
        },
        "cc.fixture",
        expected,
    )
    assert missing["classification"] == "missing-row"
    assert mismatch["classification"] == "metadata-mismatch"
    assert matching["classification"] == "matching"
    assert (
        missing["actual_equality_guard"]
        == mismatch["actual_equality_guard"]
        == "native_credential_not_applied"
    )
    assert matching["actual_equality_guard"] == "accepted"
    assert matching["metadata_fields"] == sorted(expected)
    assert "credential_info" not in matching and "credential_values" not in matching


@pytest.mark.parametrize(
    "document",
    [
        {"success": False, "credentials": []},
        {"success": True, "credentials": None},
        {
            "success": True,
            "credentials": [
                {"credential_name": "cc.fixture"},
                {"credential_name": "cc.fixture"},
            ],
        },
    ],
)
def test_invalid_native_list_cannot_be_reclassified_as_lag(document):
    with pytest.raises(ControllerError):
        classify(document, "cc.fixture", {})


def test_observer_only_adds_response_metadata_and_delegates_request_and_body():
    async def exercise():
        request = {"type": "http.request", "body": b"opaque synthetic body"}
        scope = {"type": "http", "headers": [(PID_HEADER, b"spoofed")]}
        seen = []
        original = {
            "type": "http.response.start",
            "status": 403,
            "headers": [(PID_HEADER, b"old")],
        }
        preserved = copy.deepcopy(original)

        async def application(actual_scope, receive, send):
            assert actual_scope is scope and await receive() is request
            await send(original)
            await send({"type": "http.response.body", "body": b"unchanged"})

        async def receive():
            return request

        async def send(message):
            seen.append(message)

        await ObservedResponses(application, lambda: (123, 30, False))(
            scope, receive, send
        )
        assert original == preserved
        assert seen[0]["status"] == 403
        assert dict(seen[0]["headers"])[PID_HEADER] == b"123"
        assert seen[1]["body"] == b"unchanged"

    asyncio.run(exercise())


def test_config_preserves_local_cache_db_and_native_default_poll():
    configured = configuration()
    assert configured["model_list"] == []
    assert configured["general_settings"]["store_model_in_db"] is True
    assert "proxy_config_reload_interval_seconds" not in configured["general_settings"]
    assert configured["litellm_settings"]["cache_params"] == {
        "type": "local",
        "ttl": 60,
    }
    assert "redis" not in str(configured).lower()
