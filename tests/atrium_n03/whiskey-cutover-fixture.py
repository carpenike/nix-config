"""Real installed deny-store and owner-preparation pairs inside an isolated guest."""

import copy
import hashlib
import importlib.util
import json
import os
import secrets
import sqlite3
import subprocess
import sys
import traceback
from pathlib import Path


def load(path):
    spec = importlib.util.spec_from_file_location("whiskey_preparation", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write(path, value, *, uid=0, gid=0, mode=0o600):
    body = value if isinstance(value, bytes) else (json.dumps(value) + "\n").encode()
    descriptor = os.open(
        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode
    )
    with os.fdopen(descriptor, "wb") as stream:
        os.fchown(stream.fileno(), uid, gid)
        stream.write(body)
        stream.flush()
        os.fsync(stream.fileno())


def main():
    fixture = json.loads(Path(sys.argv[1]).read_text())
    root = Path(fixture["root"])
    root.mkdir(mode=0o755)
    (root / "images").mkdir(mode=0o700)
    images = {}
    for provider in ("openai", "gemini", "openrouter"):
        path = root / "images" / provider
        write(path, secrets.token_urlsafe(32).encode())
        images["image-" + provider] = str(path)
    helper = load(fixture["helper"])
    base = fixture["configuration"]
    base["image_credentials"] = images
    groups = []

    def configuration(name):
        config = copy.deepcopy(base)
        policy = root / name
        policy.mkdir(mode=0o755)
        config["policy_directory"] = str(policy)
        config["model_approval"] = str(policy / "model-adoption.approved")
        write(
            Path(config["model_approval"]),
            b"synthetic-owner-approved-model-foundation\n",
        )
        config["settings"]["deny"]["state_directory"] = str(
            policy / "whiskey-admission"
        )
        config["legacy_deny_directory"] = str(policy / "legacy-admission")
        bootstrap = {
            "installation": config["installation"],
            "settings": config["settings"],
            "store_module": fixture["store_module"],
        }
        config["bootstrap_config"] = str(policy / "bootstrap.json")
        write(Path(config["bootstrap_config"]), bootstrap, mode=0o644)
        path = policy / "configuration.json"
        write(path, config, mode=0o644)
        return config, path, policy

    def invoke(path, *, apply=False, confirm=None, uid=0):
        command = [sys.executable, "-I", "-B", fixture["helper"], "--config", str(path)]
        if apply:
            command.append("--apply")
        if confirm is not None:
            command.extend(["--confirm-installation", confirm])
        result = subprocess.run(
            command,
            user=uid,
            group=uid,
            extra_groups=[],
            cwd="/",
            env={"HOME": "/", "LANG": "C.UTF-8"},
            capture_output=True,
            text=True,
            timeout=45,
            check=False,
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
        assert not result.stdout
        assert result.stderr.startswith("atrium_whiskey_preparation_rejected:")
        return None

    def apply(path):
        result = invoke(path, apply=True, confirm=base["installation"])
        assert result is not None and result["approved"]
        assert not result["native_application_state_changed"]
        assert not result["service_started"] and not result["model_key_minted"]
        return result

    def contents(policy):
        return {
            str(path.relative_to(policy)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in policy.rglob("*")
            if path.is_file()
        }

    def stored(directory):
        connection = sqlite3.connect(
            (directory / "admission.sqlite").as_uri() + "?mode=ro&immutable=1", uri=True
        )
        try:
            return {
                name: connection.execute(f"SELECT * FROM {name} ORDER BY id").fetchall()
                for name in ("admission_cache", "freshness_alerts")
            }
        finally:
            connection.close()

    config, path, policy = configuration("ordinary")
    before = contents(policy)
    assert invoke(path)["deny_history"] == "initialize"
    assert contents(policy) == before
    for kwargs in (
        {"apply": True},
        {"apply": True, "confirm": "foreign-installation"},
        {"uid": 1067},
    ):
        assert invoke(path, **kwargs) is None
        assert contents(policy) == before
    apply(path)
    assert (policy / "whiskey-adoption.approved").stat().st_mode & 0o777 == 0o400
    directory = policy / "whiskey-admission"
    assert directory.stat().st_uid == 1067 and directory.stat().st_mode & 0o777 == 0o700
    history = stored(directory)
    receipt = (policy / "whiskey-adoption.approved").read_bytes()
    assert apply(path)["deny_history"] == "reuse"
    assert stored(directory) == history
    assert (policy / "whiskey-adoption.approved").read_bytes() == receipt
    groups.append("read-only-plan-confirmed-native-initialize-and-identical-retry")

    def paired_refusal(name, mutate, restore):
        config, path, policy = configuration(name)
        token = mutate(config, path, policy)
        before = contents(policy)
        assert invoke(path, apply=True, confirm=base["installation"]) is None
        assert contents(policy) == before
        assert not (policy / "whiskey-adoption.approved").exists()
        restore(token, config, path, policy)
        apply(path)
        groups.append(name)

    paired_refusal(
        "missing-model-approval",
        lambda config, path, policy: Path(config["model_approval"]).rename(
            policy / "retained-model-approval"
        ),
        lambda token, config, path, policy: token.rename(config["model_approval"]),
    )
    paired_refusal(
        "foreign-private-image-custody",
        lambda config, path, policy: os.chown(Path(images["image-openai"]), 1067, 1067),
        lambda token, config, path, policy: os.chown(
            Path(images["image-openai"]), 0, 0
        ),
    )
    paired_refusal(
        "public-private-image-custody",
        lambda config, path, policy: Path(images["image-openai"]).chmod(0o644),
        lambda token, config, path, policy: Path(images["image-openai"]).chmod(0o600),
    )

    def partial(config, path, policy):
        state = policy / "whiskey-admission"
        state.mkdir(mode=0o700)
        os.chown(state, 1067, 1066)
        anchor = state / "owner.json"
        write(
            anchor,
            {"schema_version": 1, "issuer": config["settings"]["issuer"]},
            uid=1067,
            gid=1066,
        )
        return anchor

    paired_refusal(
        "partial-deny-history",
        partial,
        lambda token, config, path, policy: token.unlink(),
    )

    def legacy(config, path, policy):
        directory = Path(config["legacy_deny_directory"])
        directory.mkdir(mode=0o700)
        retained = directory / "retained-history"
        write(retained, b"synthetic-retained-native-history\n")
        return retained

    paired_refusal(
        "legacy-deny-history-is-not-reset",
        legacy,
        lambda token, config, path, policy: token.rename(
            policy / "preserved-legacy-fixture"
        ),
    )

    config, path, policy = configuration("incomplete-schema")
    apply(path)
    approval = (policy / "whiskey-adoption.approved").read_bytes()
    database = policy / "whiskey-admission/admission.sqlite"
    connection = sqlite3.connect(database)
    connection.execute("ALTER TABLE freshness_alerts RENAME TO preserved_alerts")
    connection.close()
    before = contents(policy)
    assert invoke(path, apply=True, confirm=base["installation"]) is None
    assert contents(policy) == before
    connection = sqlite3.connect(database)
    connection.execute("ALTER TABLE preserved_alerts RENAME TO freshness_alerts")
    connection.close()
    apply(path)
    assert (policy / "whiskey-adoption.approved").read_bytes() == approval
    groups.append("missing-alert-history-refused-before-native-reopen")

    config, path, policy = configuration("failed-bootstrap")
    source = Path(config["bootstrap"]).read_bytes()
    failing = policy / "failing.mjs"
    write(failing, b"process.exitCode = 1;\n", mode=0o644)
    config["bootstrap"] = str(failing)
    path.unlink()
    write(path, config, mode=0o644)
    assert invoke(path, apply=True, confirm=base["installation"]) is None
    assert not (policy / "whiskey-adoption.approved").exists()
    failing.unlink()
    write(failing, source, mode=0o644)
    apply(path)
    groups.append("failed-native-initialization-never-publishes-approval")

    config, path, policy = configuration("changed-approval")
    apply(path)
    receipt = policy / "whiskey-adoption.approved"
    original = receipt.read_bytes()
    receipt.unlink()
    write(receipt, {"schema_version": 1, "installation": "foreign"}, mode=0o400)
    before = contents(policy)
    assert invoke(path, apply=True, confirm=base["installation"]) is None
    assert contents(policy) == before
    receipt.unlink()
    write(receipt, original, mode=0o400)
    apply(path)
    groups.append("conflicting-approval-refused")

    assert helper.native_state(directory, 1067, base["settings"]["issuer"]) == "reuse"
    print(
        json.dumps(
            {
                "kind": "atrium.whiskey-cutover-fixture",
                "paired_groups": groups,
                "groups_passed": len(groups),
                "real_installed_deny_store": True,
                "production_operations": False,
                "no_model_or_household_calls": True,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    try:
        main()
    except (
        AssertionError,
        OSError,
        ValueError,
        TypeError,
        KeyError,
        sqlite3.Error,
        subprocess.SubprocessError,
    ) as error:
        print(
            json.dumps(
                {
                    "fixture_failed": type(error).__name__,
                    "locations": [
                        {"file": Path(frame.filename).name, "line": frame.lineno}
                        for frame in traceback.extract_tb(error.__traceback__)
                    ],
                }
            )
        )
        raise SystemExit(1) from None
