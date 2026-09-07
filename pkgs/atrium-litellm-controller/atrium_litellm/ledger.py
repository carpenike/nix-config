import copy
import fcntl
import os
from contextlib import contextmanager
from pathlib import Path

from .associations import HASH, Snapshot, association, integer, logical_id
from .errors import ControllerError, require
from .files import atomic_json, digest, directory, read_bytes, read_json


class Ledger:
    def __init__(self, path: Path, installation: str, issuer: str):
        self.path = path
        self.installation = installation
        self.issuer = issuer
        self.state: dict = {}
        self.dry_run = True
        self._locked = False

    def initialize(self) -> None:
        require(
            logical_id(self.installation) and bool(self.issuer), "invalid_installation"
        )
        with directory(self.path) as parent:
            try:
                require(
                    not (self.path / "ownership.json").exists(),
                    "ledger_already_initialized",
                )
                lock = os.open(
                    "ownership.lock",
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o600,
                    dir_fd=parent,
                )
                os.close(lock)
            except OSError:
                raise ControllerError("ledger_initialization_failed") from None
        initial = {
            "schema_version": 1,
            "kind": "atrium.litellm-ownership",
            "installation": self.installation,
            "issuer": self.issuer,
            "revision": 0,
            "snapshot": {"generation": 0, "sha256": None},
            "teams": {},
            "aliases": {},
            "credentials": {},
            "keys": {},
            "services": {},
        }
        atomic_json(
            self.path / "ownership.json", {"state": initial, "sha256": digest(initial)}
        )

    def load(self) -> dict:
        envelope = read_json(self.path / "ownership.json")
        require(
            set(envelope) == {"state", "sha256"}
            and isinstance(envelope["state"], dict),
            "invalid_ledger",
        )
        state = envelope["state"]
        require(envelope["sha256"] == digest(state), "corrupt_ledger")
        require(
            set(state)
            == {
                "schema_version",
                "kind",
                "installation",
                "issuer",
                "revision",
                "snapshot",
                "teams",
                "aliases",
                "credentials",
                "keys",
                "services",
            },
            "invalid_ledger",
        )
        require(
            state["schema_version"] == 1
            and state["kind"] == "atrium.litellm-ownership"
            and state["installation"] == self.installation
            and state["issuer"] == self.issuer,
            "ledger_installation_mismatch",
        )
        require(integer(state["revision"], minimum=0), "invalid_ledger_revision")
        require(
            isinstance(state["snapshot"], dict)
            and set(state["snapshot"]) == {"generation", "sha256"}
            and integer(state["snapshot"]["generation"], minimum=0),
            "invalid_ledger_snapshot",
        )
        for table in ("teams", "aliases", "credentials", "keys", "services"):
            require(isinstance(state[table], dict), "invalid_ledger_table")
        for key, row in state["keys"].items():
            require(
                HASH.fullmatch(key)
                and isinstance(row, dict)
                and row.get("source") in ("resolver", "controller"),
                "invalid_ledger_key",
            )
            association(row["association"], self.issuer)
            require(row["association"]["native_key_id"] == key, "invalid_ledger_key")
        for table in ("teams", "aliases", "credentials"):
            for name, row in state[table].items():
                require(
                    logical_id(name)
                    and isinstance(row, dict)
                    and row.get("provenance") == "controller-created"
                    and row.get("status") in ("intent", "owned")
                    and logical_id(row.get("native_id")),
                    "invalid_ledger_provenance",
                )
        return state

    @contextmanager
    def locked(self, *, dry_run: bool = False):
        require(not self._locked, "ledger_already_locked")
        read_bytes(self.path / "ownership.lock")
        with directory(self.path) as parent:
            try:
                fd = os.open(
                    "ownership.lock", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent
                )
            except OSError:
                raise ControllerError("ledger_lock_unavailable") from None
            try:
                fcntl.flock(fd, fcntl.LOCK_SH if dry_run else fcntl.LOCK_EX)
                self.state = self.load()
                self.dry_run = dry_run
                self._locked = True
                yield self
            finally:
                self._locked = False
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)

    def save(self) -> None:
        require(self._locked and not self.dry_run, "ledger_write_forbidden")
        self.state["revision"] += 1
        atomic_json(
            self.path / "ownership.json",
            {"state": self.state, "sha256": digest(self.state)},
        )

    def check_snapshot(self, snapshot: Snapshot) -> None:
        old = self.state["snapshot"]
        generation = snapshot.document["generation"]
        require(generation >= old["generation"], "snapshot_rollback")
        require(
            generation != old["generation"] or snapshot.sha256 == old["sha256"],
            "snapshot_equivocation",
        )
        for key, record in snapshot.records.items():
            if key in self.state["keys"]:
                previous = self.state["keys"][key]
                require(
                    previous["source"] == "resolver", "association_source_collision"
                )
                stable = (
                    "issuer",
                    "credential_id",
                    "native_key_id",
                    "principal_id",
                    "authority_id",
                    "domain",
                    "template_id",
                    "native_team_id",
                    "issued_at",
                    "device_id",
                )
                require(
                    all(
                        previous["association"][field] == record[field]
                        for field in stable
                    ),
                    "association_identity_changed",
                )
                require(
                    record["expires_at"] <= previous["association"]["expires_at"],
                    "association_expiry_extended",
                )
                require(
                    previous["association"]["state"] != "revoked"
                    or record["state"] == "revoked",
                    "association_revocation_rollback",
                )

    def remember(self, snapshot: Snapshot) -> None:
        self.check_snapshot(snapshot)
        require(not self.dry_run, "ledger_write_forbidden")
        for key, record in snapshot.records.items():
            old = self.state["keys"].get(key, {})
            self.state["keys"][key] = {
                **old,
                "source": "resolver",
                "association": copy.deepcopy(record),
            }
        self.state["snapshot"] = {
            "generation": snapshot.document["generation"],
            "sha256": snapshot.sha256,
        }
        self.save()
