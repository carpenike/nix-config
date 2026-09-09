"""Full real controller reconciliation over observed native worker connections."""

import copy
import json
import os
import secrets
import tempfile
import time
from io import BytesIO
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit

from atrium_litellm.associations import ProtectedSnapshotSource
from atrium_litellm.controller import Controller
from atrium_litellm.desired import Desired
from atrium_litellm.errors import ControllerError, require
from atrium_litellm.files import atomic_json
from atrium_litellm.ledger import Ledger
from atrium_litellm.native import CREDENTIAL_READBACK_SECONDS, CONTROL_ROUTES, Native
from readback_diagnostic import (
    WorkerReadResponse,
    fingerprint,
    observed,
    readback,
)


class ControllerReadbackOpener:
    """Only the credential post-check changes workers; bodies/auth stay native."""

    def __init__(
        self, pool, writer_pid, reader_pid, master, result, checkpoint, *, delete=False
    ):
        self.pool = pool
        self.writer_pid = writer_pid
        self.reader_pid = reader_pid
        self.master = master
        self.result = result
        self.checkpoint = checkpoint
        self.delete = delete
        self.identifier = None
        self.expected = None
        self.created_at = None
        self.read_count = 0
        self.origin = urlsplit(str(pool[writer_pid].base_url))

    def open(self, request, *, timeout):
        method = request.get_method()
        target = urlsplit(request.full_url)
        require(
            (target.scheme, target.netloc) == (self.origin.scheme, self.origin.netloc)
            and target.path in CONTROL_ROUTES.get(method, set()),
            "controller_probe_route_forbidden",
        )
        if method == "POST" and target.path == "/credentials":
            require(self.identifier is None, "controller_repeated_credential_post")
        credential_read = (
            method == "GET"
            and target.path == "/credentials"
            and self.identifier is not None
        )
        pid = self.writer_pid
        if credential_read:
            self.read_count += 1
            if self.read_count > 1:
                pid = self.reader_pid
                if self.delete and "fault" not in self.result:
                    response = self.pool[pid].delete(
                        "/credentials/" + self.identifier,
                        headers={"Authorization": "Bearer " + self.master},
                        timeout=timeout,
                    )
                    self.result["fault"] = {
                        **observed(response, pid),
                        "operation": "delete-only-this-case-created-credential",
                        "identity_fingerprint": fingerprint(self.identifier),
                    }
                    require(
                        response.status_code == 200
                        and response.json().get("success") is True,
                        "native_credential_delete_fault_failed",
                    )
                    response.close()
        response = self.pool[pid].request(
            method,
            request.full_url,
            headers=dict(request.header_items()),
            content=request.data,
            timeout=timeout,
        )
        observation = observed(response, pid)
        if method == "POST" and target.path == "/credentials":
            payload = json.loads(request.data)
            self.identifier = payload["credential_name"]
            self.expected = payload["credential_info"]
            self.created_at = time.monotonic()
            self.result["creation"] = {
                **observation,
                "posts": 1,
                "identity_fingerprint": fingerprint(self.identifier),
                "metadata_fingerprint": fingerprint(self.expected),
            }
        elif credential_read:
            self.result.setdefault("readbacks", []).append(
                {
                    **readback(
                        response,
                        pid,
                        self.writer_pid,
                        self.identifier,
                        self.expected,
                        self.created_at,
                    ),
                    "stage": "initial" if self.read_count == 1 else "post-create",
                    "request_timeout_seconds": timeout,
                }
            )
        self.checkpoint()
        if response.status_code != 200:
            body = BytesIO(response.content)
            status = response.status_code
            headers = response.headers
            response.close()
            raise HTTPError(
                request.full_url, status, "native request refused", headers, body
            )
        return WorkerReadResponse(response)


def isolated_desired(generated, tag):
    document = copy.deepcopy(generated)
    alias = copy.deepcopy(document["aliases"]["cc.personal.ryan.text"])
    team = copy.deepcopy(document["teams"]["cc.personal.ryan"])
    identity = "cc.readback." + tag
    alias["team"] = identity
    team["models"] = [identity]
    document["teams"] = {identity: team}
    document["aliases"] = {identity: alias}
    document["model_templates"] = {}
    return Desired.parse(document)


def verify_controller(
    endpoint,
    master,
    control,
    pool,
    writer_pid,
    generated,
    result,
    checkpoint,
    *,
    runtime_parent,
):
    reader_pid = next((pid for pid in pool if pid != writer_pid), writer_pid)
    result["controller_cases"] = []
    for delete in (False, True):
        case = {
            "case": "post-create-permanent-absence"
            if delete
            else "post-create-convergence",
            "status": "running",
            "native_operations": [],
        }
        result["controller_cases"].append(case)
        checkpoint()
        tag = secrets.token_hex(12)
        installation = "readback-" + tag
        issuer = "https://litellm.atrium.invalid"
        with tempfile.TemporaryDirectory(
            prefix="atrium-readback-controller-", dir=runtime_parent
        ) as temporary:
            root = Path(temporary).resolve()
            case["runtime_path"] = str(root)
            desired = isolated_desired(generated, tag)
            ledger = Ledger(root / "inventory", installation, issuer)
            ledger.path.mkdir(mode=0o700)
            ledger.initialize()
            now = int(time.time())
            snapshot_path = root / "input.json"
            atomic_json(
                snapshot_path,
                {
                    "schema_version": 1,
                    "kind": "atrium.litellm-associations",
                    "installation": installation,
                    "issuer": issuer,
                    "generation": 1,
                    "generated_at": now,
                    "expires_at": now + 300,
                    "associations": [],
                },
            )
            native = Native(endpoint, control, operations=case["native_operations"])
            opener = ControllerReadbackOpener(
                pool, writer_pid, reader_pid, master, case, checkpoint, delete=delete
            )
            native.opener = opener
            controller = Controller(
                desired,
                ledger,
                native,
                ProtectedSnapshotSource(
                    snapshot_path, installation, issuer, os.geteuid()
                ),
                {
                    backend: {"api_base": "http://models.atrium.invalid/v1"}
                    for backend in desired.document["model_backends"]
                },
                credential_reader=lambda *_: secrets.token_urlsafe(32),
            )
            started = time.monotonic()
            try:
                report = controller.run(rotate=False, now=now)
            except ControllerError as error:
                case["error_code"] = error.code
                if not delete or error.code != "native_credential_not_applied":
                    raise
            else:
                require(not delete, "deleted_credential_was_accepted")
                case["reconciliation"] = report
            case["elapsed_ms"] = round((time.monotonic() - started) * 1000)
            require(
                opener.created_at is not None, "controller_did_not_create_credential"
            )
            case["post_to_completion_ms"] = round(
                (time.monotonic() - opener.created_at) * 1000
            )
            case["bindings_published"] = controller.bindings_snapshot.exists()
            case["service_associations_published"] = (
                controller.service_association_snapshot.exists()
            )
            require(
                case["bindings_published"] is not delete
                and case["service_associations_published"] is not delete,
                "controller_publication_outcome_mismatch",
            )
            reads = case.get("readbacks", [])
            require(
                reads
                and reads[0]["stage"] == "initial"
                and reads[0]["writer"]
                and reads[0]["metadata_equal"],
                "initial_writer_match_not_exercised",
            )
            post_reads = [row for row in reads if row["stage"] == "post-create"]
            require(post_reads, "mandatory_post_create_read_not_exercised")
            case["post_create_initially_missing"] = (
                post_reads[0]["classification"] == "missing-row"
            )
            if delete:
                require(
                    all(row["classification"] == "missing-row" for row in post_reads)
                    and case["error_code"] == "native_credential_not_applied"
                    and CREDENTIAL_READBACK_SECONDS * 1000
                    <= case["post_to_completion_ms"]
                    <= CREDENTIAL_READBACK_SECONDS * 1000 + 1000,
                    "original_deadline_permanent_absence_not_exercised",
                )
            else:
                require(
                    post_reads[-1]["metadata_equal"]
                    and (
                        reader_pid == writer_pid
                        or case["post_create_initially_missing"]
                    ),
                    "native_post_create_convergence_not_exercised",
                )
                bindings = json.loads(controller.bindings_snapshot.read_bytes())
                require(
                    bindings["installation"] == installation
                    and set(bindings["aliases"]) == set(desired.aliases)
                    and set(bindings["teams"]) == set(desired.teams),
                    "controller_publication_not_verified",
                )
            require(
                sum(
                    row["method"] == "POST" and row["path"] == "/credentials"
                    for row in native.operations
                )
                == 1
                and not any(
                    row["path"].startswith("/key/") for row in native.operations
                ),
                "unexpected_native_credential_or_key_operation",
            )
            case.update(
                status="passed",
                budget_seconds=CREDENTIAL_READBACK_SECONDS,
                deadline_measurement_tolerance_ms=1000,
                controller_method="atrium_litellm.controller.Controller.run",
                fixture_fault_uses_bootstrap_identity=delete,
                native_response_or_authentication_mocked=False,
                worker_connections_pinned_only_in_fixture=True,
                inference_requested=False,
                service_key_rotation_exercised=False,
            )
        case["runtime_directory_removed"] = not root.exists()
        require(case["runtime_directory_removed"], "controller_runtime_cleanup_failed")
        checkpoint()
    result["controller_readback_qualified"] = True
