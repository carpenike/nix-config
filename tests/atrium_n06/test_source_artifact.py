import io
import json
import tarfile

import pytest
from source_artifact import (
    ARCHIVE_SHA256,
    REVISION,
    fingerprint,
    materialize,
    sha256,
    source_hashes,
    verify_runtime,
)


def test_existing_source_must_match_and_environment_is_not_a_source_input(tmp_path):
    files = {"server/lib/client.ts": b"export const fixture = true;"}
    materialize(files, tmp_path)
    assert source_hashes(files) == {
        "server/lib/client.ts": fingerprint(files["server/lib/client.ts"])
    }
    (tmp_path / "server/lib/client.ts").write_text("changed")
    with pytest.raises(RuntimeError, match="whiskey_materialized_source_changed"):
        materialize(files, tmp_path)


def test_compiled_bundle_hash_and_member_hashes_must_both_match(tmp_path):
    files = {"server/lib/client.ts": b"non-secret source fixture"}
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        info = tarfile.TarInfo("server/lib/client.js")
        info.size = 1
        archive.addfile(info, io.BytesIO(b"x"))
    body = output.getvalue()
    receipt = {
        "source_revision": REVISION,
        "source_archive_sha256": ARCHIVE_SHA256,
        "source_sha256": source_hashes(files),
        "archive_sha256": sha256(body),
        "members_sha256": {"server/lib/client.js": fingerprint(b"x")},
        "compiled": {
            "server/lib/client.js": {"algorithm": "sha256", "digest": sha256(b"x")}
        },
    }
    (tmp_path / "whiskey.tar.gz").write_bytes(body)
    (tmp_path / "build.json").write_text(json.dumps(receipt))
    assert verify_runtime(tmp_path, files)["source_revision"] == REVISION
    (tmp_path / "whiskey.tar.gz").write_bytes(body + b"changed")
    with pytest.raises(RuntimeError, match="whiskey_runtime_archive_changed"):
        verify_runtime(tmp_path, files)
