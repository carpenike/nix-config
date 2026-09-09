"""Source-only configuration checks; these do not create state or call native APIs."""

import copy
import hashlib
import importlib
import json
import os
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def prepared():
    if path := os.environ.get("ATRIUM_N03_PREPARED_CONFIG"):
        value = json.loads(Path(path).read_text())
    else:
        expression = (
            f'let f = builtins.getFlake "{ROOT}"; '
            f"n = import {ROOT}/tests/atrium_n03/fixture.nix "
            "{ inherit (f) inputs; }; "
            "in { fixture = n; atrium_source = toString f.inputs.atrium; }"
        )
        result = subprocess.run(
            [
                "nix",
                "eval",
                "--builders",
                "",
                "--no-write-lock-file",
                "--impure",
                "--json",
                "--expr",
                expression,
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        value = json.loads(result.stdout)
    source = Path(value["atrium_source"])
    sys.path[:0] = [
        str(source / "profiles/src"),
        str(source / "resolver/src"),
        str(ROOT / "pkgs/atrium-litellm-controller"),
        str(ROOT / "pkgs/atrium-litellm-admission"),
        str(ROOT / "tests/atrium_n03"),
    ]
    return value["fixture"]


def test_default_gate_precedes_any_native_action(prepared):
    cases = importlib.import_module("model_cases")
    with pytest.raises(RuntimeError, match="no_native_authorization"):
        cases.public_pairs(prepared, None, "", "", "", None, "", "")
    with pytest.raises(RuntimeError, match="no_native_authorization"):
        cases.known_deny_pair(prepared, None, "", "", "", "", None, None)
    probe = importlib.import_module("model_probe")
    with pytest.raises(RuntimeError, match="no_native_authorization"):
        probe.gateway_probe(prepared)
    with pytest.raises(RuntimeError, match="no_native_authorization"):
        probe.native_key_probe(prepared, "")


def test_supervisor_import_order_keeps_model_packages_actor_private(prepared, tmp_path):
    runtime = importlib.import_module("runtime")
    assert runtime.supervisor_import_paths(tmp_path) == [
        str(tmp_path / "resolver-python"),
        str(tmp_path / "native-python"),
        str(tmp_path / "fixture"),
    ]
    assert str(tmp_path / "model-python") not in runtime.supervisor_import_paths(
        tmp_path
    )


@pytest.fixture
def runtime_settings(prepared, tmp_path):
    directory = tmp_path / "gateway-config"
    directory.mkdir(mode=0o700)
    path = directory / "admission.json"
    path.write_text(json.dumps(prepared["models"]["admission"]))
    path.chmod(0o600)
    assert not path.resolve().is_relative_to("/nix/store")
    assert path.stat().st_uid == os.geteuid()
    return path


def test_actual_admission_runtime_loader_accepts_current_caller(runtime_settings):
    load_settings = importlib.import_module("atrium_admission.cli").load_settings
    settings = load_settings(runtime_settings)
    assert {producer.publisher_uid for producer in settings.producers} == {65430, 65432}
    assert len(settings.producers) == 2
    assert all(
        "atrium-n03-publications" in str(producer.path)
        for producer in settings.producers
    )


@pytest.mark.parametrize("fault", ["other-owner-metadata", "world-readable", "symlink"])
def test_actual_runtime_loader_refuses_unsafe_settings(
    runtime_settings, monkeypatch, fault
):
    cli = importlib.import_module("atrium_admission.cli")
    error_type = importlib.import_module("atrium_resolver.state").StateError
    path = runtime_settings
    if fault == "other-owner-metadata":
        # Counterfactual metadata tests the real comparison, not a kernel UID switch.
        real_fstat = os.fstat
        identity = runtime_settings.stat()

        def other_owner(descriptor):
            actual = real_fstat(descriptor)
            if (actual.st_dev, actual.st_ino) != (identity.st_dev, identity.st_ino):
                return actual
            fields = list(actual)
            fields[stat.ST_UID] = os.geteuid() + 1
            return os.stat_result(fields)

        monkeypatch.setattr(os, "fstat", other_owner)
    elif fault == "world-readable":
        path.chmod(0o644)
    else:
        path = runtime_settings.with_name("linked-settings.json")
        path.symlink_to(runtime_settings)
    with pytest.raises(error_type):
        cli.load_settings(path)


def test_accepted_r06_publication_settings_parse_and_reject_invalid_inputs(prepared):
    from pydantic import ValidationError

    settings_type = importlib.import_module("atrium_resolver.config").Settings
    settings_type.model_validate_json(json.dumps(prepared["resolver"]))
    candidate = {**prepared["resolver"], "litellm": prepared["models"]["resolver"]}
    parsed = settings_type.model_validate_json(json.dumps(candidate))
    assert (
        parsed.litellm.publication_reader_gid
        == prepared["models"]["metadataGroup"]["gid"]
    )
    assert parsed.litellm.publication_directory == Path(
        prepared["models"]["exports"]["resolver"]
    )
    for fields in (
        {"publication_reader_gid": -1},
        {"publication_reader_gid": None},
        {"publication_directory": candidate["litellm"]["runtime_directory"]},
        {"publication_directory": "/nix/store/not-runtime"},
        {"unknown_publication_input": True},
    ):
        invalid = {**candidate, "litellm": {**candidate["litellm"], **fields}}
        with pytest.raises(ValidationError):
            settings_type.model_validate_json(json.dumps(invalid))


def test_actual_n04_cli_accepts_fields_and_rejects_unknown_input(
    prepared, tmp_path, monkeypatch, capsys
):
    cli = importlib.import_module("atrium_litellm.cli")
    candidate = copy.deepcopy(prepared["models"]["controller"])
    path = tmp_path / "controller.json"
    path.write_text(json.dumps(candidate))
    monkeypatch.setattr(sys, "argv", ["controller", "init", "--config", str(path)])

    class ParsedConfiguration(Exception):
        pass

    def stop_before_state(*args):
        assert args == (
            Path(candidate["ownership_directory"]),
            candidate["installation"],
            candidate["issuer"],
        )
        raise ParsedConfiguration()

    # Exercise the accepted CLI parser; do not initialize state or native clients here.
    monkeypatch.setattr(cli, "Ledger", stop_before_state)
    with pytest.raises(ParsedConfiguration):
        cli.main()
    path.write_text(json.dumps({**candidate, "unknown_publication_input": True}))
    assert cli.main() == 1
    assert (
        json.loads(capsys.readouterr().err)["code"]
        == "invalid_controller_configuration"
    )
    error_type = importlib.import_module("atrium_litellm.errors").ControllerError
    files = importlib.import_module("atrium_litellm.files")
    with pytest.raises(error_type, match="invalid_publication_group"):
        files.validate_publication(tmp_path / "snapshot.json", -1)


def test_actual_desired_parser_accepts_generated_model_policy(prepared):
    desired_type = importlib.import_module("atrium_litellm.desired").Desired
    desired_type.parse(prepared["generated"]["litellm"])
    assert prepared["models"]["delivery"]["rotation_interval_seconds"] == 2
    assert prepared["models"]["delivery"]["overlap_seconds"] == 5


def test_case_catalog_is_unexecuted_and_reuses_existing_helpers():
    catalog = json.loads((ROOT / "tests/atrium_n03/model-cases.json").read_text())
    assert not catalog["runtime_gate_evidence"]
    assert len(catalog["cases"]) == 7
    for row in catalog["cases"]:
        assert row["status"] == "unexecuted"
        assert row["permit"] and row["deny"]
        assert all((ROOT / helper).is_file() for helper in row["helpers"])


def test_certificate_runtime_cannot_be_empty_or_unpatched(prepared, tmp_path):
    artifacts = importlib.import_module("artifacts")
    with pytest.raises(ValueError, match="declared_nix_certificate_runtime_missing"):
        artifacts.runtime_certificate_files(tmp_path)
    directory = tmp_path / "lib/python3.12/site-packages/certifi"
    directory.mkdir(parents=True)
    (directory / "__init__.py").write_text("")
    (directory / "core.py").write_text("def where(): return 'unpatched'\\n")
    with pytest.raises(ValueError, match="declared_nix_certificate_runtime_missing"):
        artifacts.runtime_certificate_files(tmp_path)


def test_runtime_tool_outputs_are_selected_by_derivation_not_order(prepared):
    build = importlib.import_module("build_runtime")
    names = ("caddy", "socat", "nftables", "iproute2", "privilege", "node", "certifi")
    identities = {name: f"/nix/store/source-{name}.drv" for name in names}
    rows = [
        {"drvPath": identities[name], "outputs": {"out": f"/nix/store/source-{name}"}}
        for name in reversed(names)
    ]
    selected = build.selected_tool_outputs(rows, identities)
    assert selected["node"][0]["drvPath"] == identities["node"]
    assert selected["certifi"][0]["drvPath"] == identities["certifi"]
    assert selected["tools"][0]["drvPath"] == identities["caddy"]
    with pytest.raises(ValueError, match="runtime_tool_derivation_set_mismatch"):
        build.selected_tool_outputs(rows[:-1], identities)
    with pytest.raises(ValueError, match="runtime_tool_derivation_set_mismatch"):
        build.selected_tool_outputs(rows + [rows[0]], identities)


class ScriptedRecoveryTransport:
    """Request-order test data only; no native authentication or network is exercised."""

    def __init__(
        self,
        fixture,
        *,
        retired_status=401,
        reuse_original=False,
        instance_id="family-models",
    ):
        self.fixture = fixture
        self.retired_status = retired_status
        self.reuse_original = reuse_original
        self.fetches = 0
        self.denied = False
        self.retired = False
        self.effects = 0
        self.events = []
        self.inference_urls = []
        self.mismatched_binding_at = None
        self.expiry = int(time.time()) + 600
        self.original = "unit-original-response-value"
        self.fresh = "unit-fresh-response-value"
        self.instance_id = instance_id
        self.instance = fixture["generated"]["resolver"]["instances"][instance_id]
        self.inference_endpoint = (
            fixture["endpoints"]["models"] + "/v1/chat/completions"
        )
        binding_path = {
            "family-models": "/family",
            "personal-models": "/personal",
        }[instance_id]
        assert self.instance["target"] == fixture["endpoints"]["models"] + binding_path
        assert self.instance["target"] != self.inference_endpoint
        assert fixture["models"]["inferenceEndpoint"] == self.inference_endpoint

    def call(self, action, **fields):
        assert action == "request"
        method, url = fields["method"], fields["url"]
        bearer = fields["headers"]["Authorization"]
        if url.endswith("/v1/manifests"):
            assert bearer == "Bearer unit-owner-identity"
            self.fetches += 1
            self.events.append("manifest")
            assert fields["body"] == {
                "domain": self.instance["domain"],
                "include_models": True,
            }
            body = {
                "manifest": {
                    "instances": [
                        {
                            "display_name": self.instance["display_name"],
                            "credential_state": "prepared",
                            "instance_ref": f"unit-instance-{self.fetches}",
                            "auth_ref": f"unit-auth-{self.fetches}",
                        }
                    ]
                }
            }
        elif url.endswith("/v1/credentials/redeem"):
            assert bearer == "Bearer unit-owner-identity"
            assert fields["body"]["auth_ref"] == f"unit-auth-{self.fetches}"
            assert fields["body"]["instance_ref"] == f"unit-instance-{self.fetches}"
            self.events.append("redeem")
            binding_instance = self.instance_id
            if self.fetches == self.mismatched_binding_at:
                binding_instance = {
                    "family-models": "personal-models",
                    "personal-models": "family-models",
                }[self.instance_id]
            body = {
                "target": self.fixture["generated"]["resolver"]["instances"][
                    binding_instance
                ]["target"],
                "credential": {
                    "profile": "litellm-key",
                    "token": self.original
                    if self.fetches == 1 or self.reuse_original
                    else self.fresh,
                    "expires_at": self.expiry,
                },
            }
        elif url.endswith("/v1/denies"):
            assert bearer == "Bearer unit-deny-administrator"
            assert fields["body"]["identifier"] == (
                "sha256:" + hashlib.sha256(self.original.encode()).hexdigest()
            )
            self.denied = method == "POST"
            if self.denied:
                self.retired = True
            self.events.append("deny-added" if self.denied else "deny-removed")
            body = {}
        else:
            assert url == self.inference_endpoint
            self.inference_urls.append(url)
            original = bearer == "Bearer " + self.original
            assert original or bearer == "Bearer " + self.fresh
            if original and self.retired:
                self.events.append("old-refusal")
                return {"status": self.retired_status, "body": "{}"}
            self.effects += 1
            self.events.append("old-permit" if original else "fresh-permit")
            body = {"choices": [{"message": {"content": "unit-response"}}]}
        return {"status": 200, "body": json.dumps(body)}

    def observation(self, digest):
        assert digest == hashlib.sha256(self.original.encode()).hexdigest()
        return {
            "kind": "native-key-info",
            "issuer": self.fixture["endpoints"]["models"],
            "native_key_id": digest,
            "observer_uid": self.fixture["models"]["roles"]["resolver"]["uid"],
            "present": not self.retired,
            "expires_at": self.expiry if not self.retired else None,
        }


@pytest.fixture
def recovery_control_flow(prepared):
    # In-memory opt-in for scripted transport, not runtime activation.
    fixture = copy.deepcopy(prepared)
    fixture["modelPlaneReady"] = True
    assert fixture["models"]["acceptedPublisherPins"]["verified"]
    return fixture


def run_scripted_recovery(fixture, transport, observation=None):
    cases = importlib.import_module("model_cases")
    return cases.known_deny_pair(
        fixture,
        transport,
        "unit-owner-identity",
        transport.instance_id,
        "unit-model",
        "unit-deny-administrator",
        lambda: {"effects": transport.effects},
        observation or transport.observation,
    )


@pytest.mark.parametrize("instance_id", ["family-models", "personal-models"])
def test_healthy_recovery_fetches_fresh_reference_and_retains_old_refusal(
    recovery_control_flow, instance_id
):
    transport = ScriptedRecoveryTransport(
        recovery_control_flow, instance_id=instance_id
    )
    result = run_scripted_recovery(recovery_control_flow, transport)
    assert transport.events == [
        "manifest",
        "redeem",
        "old-permit",
        "deny-added",
        "old-refusal",
        "deny-removed",
        "manifest",
        "redeem",
        "fresh-permit",
        "old-refusal",
    ]
    assert transport.effects == 2
    assert transport.inference_urls == [transport.inference_endpoint] * 4
    assert result["denials"] == [401, 401]
    assert result["recovery"] == "fresh-r03-r06-delivery"
    assert result["original_key_still_denied"]
    assert result["live_n05_hook_coverage"] is False


@pytest.mark.parametrize("instance_id", ["family-models", "personal-models"])
@pytest.mark.parametrize("delivery_number", [1, 2])
def test_mismatched_logical_binding_is_refused_before_inference(
    recovery_control_flow, instance_id, delivery_number
):
    transport = ScriptedRecoveryTransport(
        recovery_control_flow, instance_id=instance_id
    )
    transport.mismatched_binding_at = delivery_number
    with pytest.raises(AssertionError, match="model_delivery_target_mismatch"):
        run_scripted_recovery(recovery_control_flow, transport)
    assert "fresh-permit" not in transport.events
    assert transport.inference_urls == [transport.inference_endpoint] * (
        0 if delivery_number == 1 else 2
    )


@pytest.mark.parametrize("status", [200, 403, 503])
def test_retirement_does_not_broaden_or_attribute_other_statuses(
    recovery_control_flow, status
):
    transport = ScriptedRecoveryTransport(recovery_control_flow, retired_status=status)
    with pytest.raises(AssertionError, match="native_auth_refusal_not_observed"):
        run_scripted_recovery(recovery_control_flow, transport)
    assert transport.fetches == 1
    assert transport.events[-1] == "deny-removed"


def test_recovery_refuses_a_reused_original_credential(recovery_control_flow):
    transport = ScriptedRecoveryTransport(recovery_control_flow, reuse_original=True)
    with pytest.raises(AssertionError, match="fresh_recovery_credential_required"):
        run_scripted_recovery(recovery_control_flow, transport)
    assert "fresh-permit" not in transport.events


def test_unrelated_native_observation_cannot_classify_denial(recovery_control_flow):
    transport = ScriptedRecoveryTransport(recovery_control_flow)

    def wrong_observation(digest):
        return {**transport.observation(digest), "native_key_id": "unrelated"}

    with pytest.raises(AssertionError, match="matching_private_native_observation"):
        run_scripted_recovery(recovery_control_flow, transport, wrong_observation)
    assert "deny-added" not in transport.events


def test_expiry_cannot_substitute_for_healthy_retirement(recovery_control_flow):
    transport = ScriptedRecoveryTransport(recovery_control_flow)
    transport.expiry = int(time.time()) + 1
    with pytest.raises(AssertionError, match="retirement_probe_must_not_be_expiry"):
        run_scripted_recovery(recovery_control_flow, transport)
    assert "deny-added" not in transport.events


def test_failed_native_readback_does_not_become_same_key_recovery(
    recovery_control_flow,
):
    transport = ScriptedRecoveryTransport(recovery_control_flow)

    def failed_readback(digest):
        if transport.denied:
            raise RuntimeError("source-test-native-readback-unavailable")
        return transport.observation(digest)

    with pytest.raises(RuntimeError, match="native-readback-unavailable"):
        run_scripted_recovery(recovery_control_flow, transport, failed_readback)
    assert transport.fetches == 1
    assert transport.events[-1] == "deny-removed"
    assert "fresh-permit" not in transport.events
