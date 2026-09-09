"""Source-only configuration checks; these do not create state or call native APIs."""

import ast
import importlib
import json
import os
import subprocess
import sys
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
        cases.known_deny_pair(prepared, None, "", "", "", None)
    probe = importlib.import_module("model_probe")
    with pytest.raises(RuntimeError, match="no_native_authorization"):
        probe.gateway_probe(prepared)


def test_actual_admission_settings_accept_live_export_references(prepared):
    settings_type = importlib.import_module("atrium_admission.models").Settings
    settings = settings_type.model_validate_json(
        json.dumps(prepared["models"]["admission"])
    )
    assert {producer.publisher_uid for producer in settings.producers} == {65430, 65432}
    assert len(settings.producers) == 2
    assert all(
        "atrium-n03-publications" in str(producer.path)
        for producer in settings.producers
    )


def test_current_r06_fields_are_an_explicit_pin_blocker(prepared):
    from pydantic import ValidationError

    settings_type = importlib.import_module("atrium_resolver.config").Settings
    settings_type.model_validate_json(json.dumps(prepared["resolver"]))
    candidate = {**prepared["resolver"], "litellm": prepared["models"]["resolver"]}
    with pytest.raises(ValidationError) as failure:
        settings_type.model_validate_json(json.dumps(candidate))
    assert {
        (tuple(error["loc"]), error["type"]) for error in failure.value.errors()
    } == {
        (("litellm", "publication_directory"), "extra_forbidden"),
        (("litellm", "publication_reader_gid"), "extra_forbidden"),
    }


def test_current_n04_field_is_an_explicit_pin_blocker(prepared):
    source = ROOT / "pkgs/atrium-litellm-controller/atrium_litellm/cli.py"
    calls = [
        node
        for node in ast.walk(ast.parse(source.read_text()))
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "fields"
    ]
    assert len(calls) == 1
    allowed = ast.literal_eval(calls[0].args[1])
    candidate = prepared["models"]["controller"]
    assert set(candidate) - allowed == {"publication_reader_gid"}
    associations = importlib.import_module("atrium_litellm.associations")
    error_type = importlib.import_module("atrium_litellm.errors").ControllerError
    with pytest.raises(error_type, match="invalid_controller_configuration"):
        associations.fields(candidate, allowed, "invalid_controller_configuration")


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
