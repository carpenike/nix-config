"""Protected group publication; actual service-token defaults remain independent."""

import os
import stat
import json
import sys
import time
from contextlib import nullcontext
from pathlib import Path

import pytest

from atrium_litellm.errors import ControllerError
from atrium_litellm.files import atomic_json, atomic_publication_json, read_json


@pytest.fixture
def destination(tmp_path):
    directory = tmp_path / "public"
    directory.mkdir(mode=0o700)
    os.chown(directory, -1, os.getegid())
    directory.chmod(0o2750)
    return directory / "native-bindings.json", os.getegid()


def value(generation):
    return {"kind": "atrium.litellm-bindings", "generation": generation}


def test_existing_private_and_service_token_atomic_modes_do_not_change(tmp_path):
    private, token = tmp_path / "private.json", tmp_path / "token.json"
    atomic_json(private, value(1))
    atomic_json(token, {"synthetic": True}, secret=True, mode=0o640, group=os.getegid())
    assert stat.S_IMODE(private.stat().st_mode) == 0o600
    assert stat.S_IMODE(token.stat().st_mode) == 0o640


def test_publication_is_complete_before_exposure_and_atomically_replaced(
    destination, monkeypatch
):
    path, gid = destination
    atomic_publication_json(path, value(1), gid)
    previous = path.stat()
    replace = os.replace

    def inspect(source, target, **options):
        staged = path.parent / source
        assert read_json(staged) == value(2)
        assert stat.S_IMODE(staged.stat().st_mode) == 0o640
        assert staged.stat().st_gid == gid
        assert read_json(path) == value(1)
        return replace(source, target, **options)

    monkeypatch.setattr(os, "replace", inspect)
    atomic_publication_json(path, value(2), gid)
    assert path.stat().st_ino != previous.st_ino
    assert read_json(path) == value(2)


@pytest.mark.parametrize(
    "fault",
    ["missing", "writable", "world-readable", "symlink", "hardlink", "partial", "gid"],
)
def test_unsafe_publications_are_refused(destination, fault):
    path, gid = destination
    atomic_publication_json(path, value(1), gid)
    if fault == "missing":
        path.unlink()
        path.parent.rmdir()
    elif fault == "writable":
        path.parent.chmod(0o2770)
    elif fault == "world-readable":
        path.chmod(0o644)
    elif fault == "symlink":
        path.rename(path.with_name("original"))
        path.symlink_to(path.with_name("original"))
    elif fault == "hardlink":
        os.link(path, path.with_name("alias"))
    elif fault == "partial":
        path.write_bytes(b'{"kind":')
    else:
        gid = 2**32 - 1
    with pytest.raises(ControllerError):
        atomic_publication_json(path, value(2), gid)


def test_failed_publication_retains_working_contents_and_age(destination, monkeypatch):
    path, gid = destination
    atomic_publication_json(path, value(1), gid)
    before = path.read_bytes()
    identity = path.stat().st_ino

    def fail(_descriptor):
        raise OSError("synthetic_stage_failure")

    monkeypatch.setattr(os, "fsync", fail)
    with pytest.raises(ControllerError):
        atomic_publication_json(path, value(2), gid)
    assert path.read_bytes() == before and path.stat().st_ino == identity
    assert not list(path.parent.glob(".*.next"))


@pytest.mark.parametrize(
    "fault", ["directory-link", "staging-link", "staging-replaced", "staging-mode"]
)
def test_changed_directory_or_staging_cannot_be_published(
    destination, monkeypatch, fault
):
    path, gid = destination
    atomic_publication_json(path, value(1), gid)
    moved = path.parent.with_name("preserved-directory")
    original = os.fsync
    invoked = False

    def mutate(descriptor):
        nonlocal invoked
        if not invoked and stat.S_ISREG(os.fstat(descriptor).st_mode):
            invoked = True
            staged = next(path.parent.glob(".*.next"))
            if fault == "directory-link":
                path.parent.rename(moved)
                path.parent.symlink_to(moved)
            elif fault == "staging-link":
                os.link(staged, path.parent / "unexpected-staging-link")
            elif fault == "staging-replaced":
                staged.unlink()
                staged.write_bytes(b'{"kind":"atrium.litellm-bindings","generation":2}')
                staged.chmod(0o640)
            else:
                staged.chmod(0o660)
        return original(descriptor)

    monkeypatch.setattr(os, "fsync", mutate)
    with pytest.raises(ControllerError):
        atomic_publication_json(path, value(2), gid)
    if path.parent.is_symlink():
        path.parent.unlink()
        moved.rename(path.parent)
    assert read_json(path) == value(1)
    assert not list(path.parent.glob(".*.next"))


def test_directory_sync_failure_surfaces_uncertain_durability(destination, monkeypatch):
    path, gid = destination
    atomic_publication_json(path, value(1), gid)
    original = os.fsync
    replace = os.replace
    directory_syncs = 0
    replacements = 0
    broken = True
    snapshot = {**value(2), "generated_at": 123, "expires_at": 423}

    def fail_directory(descriptor):
        nonlocal directory_syncs
        if stat.S_ISDIR(os.fstat(descriptor).st_mode):
            directory_syncs += 1
            if broken:
                raise OSError("synthetic_uncertain_durability")
        return original(descriptor)

    def observed_replace(*args, **kwargs):
        nonlocal replacements
        replacements += 1
        return replace(*args, **kwargs)

    monkeypatch.setattr(os, "fsync", fail_directory)
    monkeypatch.setattr(os, "replace", observed_replace)
    with pytest.raises(ControllerError, match="atomic_publication_failed"):
        atomic_publication_json(path, snapshot, gid)
    visible = path.stat()
    assert read_json(path) == snapshot and directory_syncs == replacements == 1
    with pytest.raises(ControllerError, match="atomic_publication_failed"):
        atomic_publication_json(path, snapshot, gid)
    assert directory_syncs == 2 and replacements == 1
    broken = False
    atomic_publication_json(path, snapshot, gid)
    assert directory_syncs == 3 and replacements == 1
    assert read_json(path) == snapshot
    assert (path.stat().st_ino, path.stat().st_mtime_ns) == (
        visible.st_ino,
        visible.st_mtime_ns,
    )


def test_identical_retry_requires_directory_sync_without_rewriting(monkeypatch):
    from atrium_litellm import files

    parent = 71
    snapshot = {**value(2), "generated_at": 123, "expires_at": 423}
    payload = files.canonical(snapshot) + b"\n"
    monkeypatch.setattr(
        files, "publication_directory", lambda *_args: nullcontext(parent)
    )
    monkeypatch.setattr(files, "_publication_existing", lambda *_args: payload)
    calls = []
    broken = True

    def sync(descriptor):
        assert descriptor == parent
        calls.append(descriptor)
        if broken:
            raise OSError("synthetic_uncertain_durability")

    def no_rewrite(*_args, **_kwargs):
        pytest.fail("Identical publication attempted a replacement")

    monkeypatch.setattr(os, "fsync", sync)
    monkeypatch.setattr(os, "replace", no_rewrite)
    with pytest.raises(ControllerError, match="atomic_publication_failed"):
        atomic_publication_json(
            Path("/run/nonsecret/native-bindings.json"), snapshot, os.getegid()
        )
    assert calls == [parent]
    broken = False
    atomic_publication_json(
        Path("/run/nonsecret/native-bindings.json"), snapshot, os.getegid()
    )
    assert calls == [parent, parent]


@pytest.mark.parametrize("group", [None, "current", True, -1, "untrusted-group"])
def test_cli_optional_group_is_validated_before_state_initialization(
    tmp_path, monkeypatch, capsys, group
):
    from atrium_litellm.cli import main

    private = tmp_path / "private"
    private.mkdir(mode=0o700)
    public = tmp_path / "public"
    public.mkdir(mode=0o700)
    os.chown(public, -1, os.getegid())
    public.chmod(0o2750)
    source = tmp_path / "input.json"
    now = int(time.time())
    atomic_json(
        source,
        {
            "schema_version": 1,
            "kind": "atrium.litellm-associations",
            "installation": "publication-cli",
            "issuer": "https://models.atrium.invalid",
            "generation": 1,
            "generated_at": now,
            "expires_at": now + 300,
            "associations": [],
        },
    )
    config = {
        "schema_version": 1,
        "environment": "isolated",
        "installation": "publication-cli",
        "issuer": "https://models.atrium.invalid",
        "endpoint": "https://models.atrium.invalid",
        "desired_state": str(tmp_path / "unused-desired.json"),
        "ownership_directory": str(private),
        "association_snapshot": str(source),
        "association_publisher_uid": os.geteuid(),
        "management_key_file": str(private / "unused-management"),
        "backend_transports": {},
        "service_delivery": {},
        "service_association_snapshot": str(public / "service-associations.json"),
        "bindings_snapshot": str(public / "native-bindings.json"),
    }
    if group is not None:
        config["publication_reader_gid"] = os.getegid() if group == "current" else group
    configured = tmp_path / "configuration.json"
    configured.write_text(json.dumps(config))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "atrium-litellm-controller",
            "init",
            "--config",
            str(configured),
            "--confirm-new-installation",
            "publication-cli",
        ],
    )
    result = main()
    output = capsys.readouterr()
    if group in (None, "current"):
        assert result == 0 and (private / "ownership.json").exists()
        assert json.loads(output.out)["adoptions"] == 0
    else:
        assert result == 1 and not (private / "ownership.json").exists()
        assert json.loads(output.err)["code"] == "invalid_publication_group"
