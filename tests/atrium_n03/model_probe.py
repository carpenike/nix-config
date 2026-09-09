"""Read-only gateway-UID publication/custody probe for the later native assembly."""

import errno
import json
import os
from pathlib import Path


def native_key_probe(fixture: dict, digest: str) -> dict:
    """Read native existence through the real R06 control client; never revoke here."""
    from model_cases import require_native_assignment

    require_native_assignment(fixture)
    from atrium_resolver.litellm_native import NativeKeyClient, native_expiry

    models = fixture["models"]
    if os.geteuid() != models["roles"]["resolver"]["uid"] or os.geteuid() == 0:
        raise RuntimeError("actual_resolver_probe_uid_required")
    configuration = models["resolver"]
    client = NativeKeyClient(
        configuration["endpoint"], Path(configuration["controller_key_file"])
    )
    try:
        record = client.info(digest)
    finally:
        client.close()
    return {
        "kind": "native-key-info",
        "issuer": configuration["endpoint"],
        "native_key_id": digest,
        "observer_uid": os.geteuid(),
        "present": record is not None,
        "expires_at": None if record is None else native_expiry(record["expires"]),
    }


def gateway_probe(fixture: dict) -> dict:
    from model_cases import require_native_assignment

    require_native_assignment(fixture)
    from atrium_admission.cli import load_settings
    from atrium_admission.producers import read_producer
    from atrium_admission.state import protected_document
    from atrium_resolver.policy_schema import PolicyDocument

    models = fixture["models"]
    if os.geteuid() != models["roles"]["gateway"]["uid"] or os.geteuid() == 0:
        raise RuntimeError("actual_gateway_uid_required")
    status = dict(
        line.split(":", 1)
        for line in Path("/proc/self/status").read_text().splitlines()
        if ":" in line
    )
    if status["NoNewPrivs"].strip() != "1" or any(
        int(status[name].strip(), 16)
        for name in ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb")
    ):
        raise RuntimeError("gateway_probe_retained_privileges")
    if models["metadataGroup"]["gid"] not in os.getgroups() or models["deliveryGroup"][
        "gid"
    ] in {*os.getgroups(), os.getegid()}:
        raise RuntimeError("gateway_publication_groups_not_separate")
    settings_path = Path(os.environ["ATRIUM_ADMISSION_SETTINGS"])
    if settings_path != Path(models["admissionSettingsPath"]):
        raise RuntimeError("gateway_settings_runtime_path_mismatch")
    settings = load_settings(settings_path)
    policy = PolicyDocument.model_validate_json(
        json.dumps(
            protected_document(settings.policy_path, settings.policy_publisher_uid)
        )
    )
    import time

    snapshots = []
    for producer in settings.producers:
        generation, issued_at, _, records = read_producer(
            producer, settings, policy, int(time.time())
        )
        snapshots.append(
            {
                "producer": producer.id,
                "generation": generation,
                "issued_at": issued_at,
                "records": len(records),
            }
        )
        try:
            descriptor = os.open(producer.path, os.O_WRONLY | os.O_NOFOLLOW)
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EROFS):
                raise
        else:
            os.close(descriptor)
            raise AssertionError("metadata_reader_can_write_publication")
    custody = []
    for path in (
        fixture["state"]["resolver"],
        models["private"]["resolver"],
        models["private"]["controller"],
        fixture["runtime"] + "/provider-input",
        str(Path(models["delivery"]["key_path"]).parent),
    ):
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.ENOENT):
                raise
            custody.append(
                {
                    "boundary": "not-mounted"
                    if error.errno == errno.ENOENT
                    else "permission-refused",
                    "path": path,
                }
            )
        else:
            os.close(descriptor)
            raise AssertionError(
                "gateway_can_traverse_private_publisher_or_token_custody"
            )
    return {
        "uid": os.geteuid(),
        "pid": os.getpid(),
        "settings_loader": "atrium_admission.cli.load_settings",
        "settings_path": str(settings_path),
        "snapshots": snapshots,
        "reader_writes_refused": True,
        "private_custody": custody,
        "owner_existence_counterpart_required": True,
    }
