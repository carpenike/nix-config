"""Prepare the selected Whiskey adapter without changing native application state."""

import argparse
import fcntl
import grp
import hashlib
import json
import os
import pwd
import re
import sqlite3
import stat
import subprocess
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path


class Rejected(ValueError):
    pass


def require(condition, code):
    if not condition:
        raise Rejected(code)


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, "duplicate_json_key")
        value[key] = item
    return value


def custody(path, *, uid=0, private=False, directory=False, public=False):
    require(path.is_absolute() and ".." not in path.parts, "absolute_path_required")
    resolved = path.resolve(strict=True)
    if resolved != path:
        require(
            public
            and (
                resolved.is_relative_to("/nix/store")
                or (
                    path.is_relative_to("/run/secrets")
                    and resolved.is_relative_to("/run")
                )
            ),
            "symlink_refused",
        )
    if private:
        require(
            not resolved.is_relative_to("/nix/store"), "runtime_private_input_required"
        )
    for parent in resolved.parents:
        info = parent.lstat()
        require(
            stat.S_ISDIR(info.st_mode)
            and info.st_uid in (0, uid)
            and (
                not info.st_mode & 0o022
                or (parent == Path("/nix/store") and info.st_mode & stat.S_ISVTX)
            )
            and not (parent / ".git").exists(),
            "unsafe_ancestor",
        )
    info = resolved.lstat()
    require(
        (stat.S_ISDIR if directory else stat.S_ISREG)(info.st_mode)
        and info.st_uid == uid
        and not info.st_mode & (0o077 if private else 0o022)
        and (
            directory
            or info.st_nlink == 1
            or (public and resolved.is_relative_to("/nix/store"))
        ),
        "unsafe_custody",
    )
    return resolved, info


def read_json(path, *, uid=0, private=False, public=False):
    path, _ = custody(path, uid=uid, private=private, public=public)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        body = stream.read(1024 * 1024 + 1)
    require(0 < len(body) <= 1024 * 1024, "invalid_document_size")
    return json.loads(body, object_pairs_hook=unique_object)


def encoded(value):
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n"
    ).encode()


def digest(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def native_state(directory, uid, issuer):
    if not os.path.lexists(directory):
        return "initialize"
    custody(directory, uid=uid, private=True, directory=True)
    entries = set(os.listdir(directory))
    if not entries:
        return "initialize"
    require(
        {"owner.json", "admission.sqlite"}
        <= entries
        <= {
            "owner.json",
            "admission.sqlite",
            "admission.sqlite-wal",
            "admission.sqlite-shm",
            "initialization.started",
        },
        "partial_deny_history",
    )
    for name in entries:
        custody(directory / name, uid=uid, private=True)
    require(
        read_json(directory / "owner.json", uid=uid, private=True)
        == {"schema_version": 1, "issuer": issuer},
        "deny_issuer_conflict",
    )
    database = directory / "admission.sqlite"
    sidecars = [Path(str(database) + suffix) for suffix in ("-wal", "-shm")]
    exists = [os.path.lexists(path) for path in sidecars]
    require(all(exists) or not any(exists), "partial_deny_sidecars")
    connection = sqlite3.connect(
        database.as_uri() + "?mode=ro" + ("" if all(exists) else "&immutable=1"),
        uri=True,
        isolation_level=None,
    )
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("BEGIN")
        require(
            connection.execute("PRAGMA quick_check").fetchone()[0] == "ok",
            "deny_integrity_failed",
        )
        for table in ("admission_cache", "freshness_alerts"):
            columns = list(
                connection.execute(
                    'SELECT name,type,"notnull",pk FROM pragma_table_info(?) ORDER BY cid',
                    (table,),
                )
            )
            require(
                columns == [("id", "INTEGER", 0, 1), ("document", "TEXT", 1, 0)],
                "deny_schema_incomplete",
            )
        require(
            connection.execute(
                "SELECT count(*) FROM admission_cache WHERE id=1"
            ).fetchone()[0]
            == 1,
            "deny_cache_missing",
        )
    finally:
        connection.close()
    require(
        [os.path.lexists(path) for path in sidecars] == exists, "deny_sidecars_changed"
    )
    return "reuse"


def preflight(config):
    require(
        set(config)
        == {
            "schema_version",
            "installation",
            "policy_directory",
            "legacy_deny_directory",
            "settings",
            "model",
            "identity",
            "image_credentials",
            "egress",
            "model_approval",
            "node",
            "bootstrap",
            "bootstrap_config",
            "network_helper",
        }
        and config["schema_version"] == 1,
        "invalid_configuration",
    )
    policy = Path(config["policy_directory"])
    custody(policy, directory=True)
    identity = config["identity"]
    require(
        set(identity) == {"uid", "gid", "user", "group"}
        and all(
            type(identity[name]) is int and 0 < identity[name] < 2**31
            for name in ("uid", "gid")
        )
        and all(
            re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", identity[name])
            for name in ("user", "group")
        ),
        "invalid_consumer_identity",
    )
    try:
        account = pwd.getpwuid(identity["uid"])
    except KeyError:
        account = None
    require(
        account is None or account.pw_name == identity["user"],
        "consumer_uid_already_owned",
    )
    require(
        grp.getgrgid(identity["gid"]).gr_name == identity["group"],
        "consumer_group_conflict",
    )
    settings = config["settings"]
    directory = Path(settings["deny"]["state_directory"])
    require(
        directory == policy / "whiskey-admission", "dedicated_deny_directory_required"
    )
    legacy = Path(config["legacy_deny_directory"])
    require(legacy != directory and legacy.is_absolute(), "invalid_legacy_binding")
    require(
        not os.path.lexists(legacy) or (legacy.is_dir() and not list(legacy.iterdir())),
        "retained_legacy_deny_history_requires_review",
    )
    _, approval = custody(Path(config["model_approval"]), private=True)
    require(approval.st_size > 0, "model_adoption_required")
    model = config["model"]
    require(
        model["schema_version"] == 1
        and model["installation"] == config["installation"]
        and model["key_owner_uid"] != identity["uid"]
        and model["isolated_harness"] == settings["isolated_harness"],
        "model_binding_conflict",
    )
    for name in ("node", "bootstrap", "bootstrap_config", "network_helper"):
        custody(Path(config[name]), public=True)
    bootstrap = read_json(Path(config["bootstrap_config"]), public=True)
    require(
        set(bootstrap) == {"installation", "settings", "store_module"}
        and bootstrap["installation"] == config["installation"]
        and bootstrap["settings"] == settings,
        "bootstrap_binding_conflict",
    )
    custody(Path(bootstrap["store_module"]), public=True)
    images = config["image_credentials"]
    require(
        set(images) == {"image-openai", "image-gemini", "image-openrouter"},
        "exact_image_sources_required",
    )
    require(len(set(images.values())) == 3, "distinct_image_sources_required")
    for path in images.values():
        _, info = custody(Path(path), private=True, public=True)
        require(0 < info.st_size <= 16384, "invalid_image_credential_size")
    egress = config["egress"]
    require(egress["uid"] == identity["uid"], "network_identity_conflict")
    spec = spec_from_file_location("whiskey_network", config["network_helper"])
    require(spec is not None and spec.loader is not None, "network_helper_unavailable")
    network = module_from_spec(spec)
    spec.loader.exec_module(network)
    network.resolve(egress)
    state = native_state(directory, identity["uid"], settings["issuer"])
    expected = {
        "schema_version": 1,
        "installation": config["installation"],
        "settings_sha256": digest(settings),
        "model_sha256": digest(model),
        "identity": identity,
        "image_sources_sha256": digest(images),
        "egress_sha256": digest(egress),
    }
    receipt = policy / "whiskey-adoption.approved"
    if os.path.lexists(receipt):
        require(state == "reuse", "approved_deny_history_missing")
        require(read_json(receipt, private=True) == expected, "approval_conflict")
    return directory, state, expected


def run_native(config, *, initialize):
    identity = config["identity"]
    command = [
        config["node"],
        config["bootstrap"],
        "--config",
        config["bootstrap_config"],
        "--confirm-new-installation"
        if initialize
        else "--confirm-existing-installation",
        config["installation"],
    ]
    result = subprocess.run(
        command,
        user=identity["uid"],
        group=identity["gid"],
        extra_groups=[],
        cwd="/",
        env={"HOME": "/", "LANG": "C.UTF-8"},
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=30,
        check=False,
        umask=0o077,
    )
    require(result.returncode == 0, "native_deny_validation_failed")


def publish(path, value):
    if os.path.lexists(path):
        require(read_json(path, private=True) == value, "approval_conflict")
        return
    pending = path.parent / ("." + path.name + ".new")
    descriptor = os.open(
        pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400
    )
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.link(pending, path, follow_symlinks=False)
    finally:
        pending.unlink()
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirm-installation")
    args = parser.parse_args()
    try:
        require(os.geteuid() == 0, "owner_root_required")
        config = read_json(args.config, public=True)
        require(
            (args.apply and args.confirm_installation == config["installation"])
            or (not args.apply and args.confirm_installation is None),
            "explicit_apply_confirmation_required",
        )
        policy = Path(config["policy_directory"])
        custody(policy, directory=True)
        descriptor = os.open(policy, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            directory, state, receipt = preflight(config)
            if args.apply:
                if not directory.exists():
                    directory.mkdir(mode=0o700)
                    os.chown(
                        directory, config["identity"]["uid"], config["identity"]["gid"]
                    )
                run_native(config, initialize=state == "initialize")
                require(
                    native_state(
                        directory,
                        config["identity"]["uid"],
                        config["settings"]["issuer"],
                    )
                    == "reuse",
                    "deny_initialization_unverified",
                )
                run_native(config, initialize=False)
                publish(policy / "whiskey-adoption.approved", receipt)
            print(
                json.dumps(
                    {
                        "kind": "atrium.whiskey-preparation",
                        "mode": "apply" if args.apply else "plan",
                        "deny_history": state,
                        "approved": args.apply,
                        "native_application_state_changed": False,
                        "service_started": False,
                        "model_key_minted": False,
                    },
                    sort_keys=True,
                )
            )
        finally:
            os.close(descriptor)
    except Rejected as error:
        raise SystemExit("atrium_whiskey_preparation_rejected:" + str(error)) from None
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        RecursionError,
        sqlite3.Error,
        subprocess.SubprocessError,
    ):
        raise SystemExit(
            "atrium_whiskey_preparation_rejected:invalid_configuration_or_state"
        ) from None


if __name__ == "__main__":
    main()
