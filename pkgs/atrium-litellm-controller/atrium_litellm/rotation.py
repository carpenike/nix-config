import hashlib
import os
import secrets
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from .associations import HASH, fields, integer
from .errors import ControllerError, require
from .files import atomic_json, read_json
from .native import NativeError, expiration, metadata, verify_key


@dataclass(frozen=True)
class ServiceKey:
    installation: str
    issuer: str
    template_id: str
    native_key_id: str
    publication_id: str
    expires_at: int
    token: str = field(repr=False)

    def document(self) -> dict:
        return {
            "schema_version": 1,
            "kind": "atrium.litellm-service-key",
            "installation": self.installation,
            "issuer": self.issuer,
            "template_id": self.template_id,
            "native_key_id": self.native_key_id,
            "publication_id": self.publication_id,
            "expires_at": self.expires_at,
            "token": self.token,
        }

    @classmethod
    def read(
        cls, path: Path, *, owner_uid: int, now: int | None = None
    ) -> "ServiceKey":
        value = read_json(path, uid=owner_uid, secret=True)
        fields(
            value,
            {
                "schema_version",
                "kind",
                "installation",
                "issuer",
                "template_id",
                "native_key_id",
                "publication_id",
                "expires_at",
                "token",
            },
            "invalid_service_publication",
        )
        now = int(time.time()) if now is None else now
        require(
            value["schema_version"] == 1
            and value["kind"] == "atrium.litellm-service-key"
            and isinstance(value["token"], str)
            and value["token"].startswith("sk-")
            and isinstance(value["native_key_id"], str)
            and HASH.fullmatch(value["native_key_id"])
            and hashlib.sha256(value["token"].encode()).hexdigest()
            == value["native_key_id"]
            and integer(value["expires_at"])
            and now < value["expires_at"]
            and isinstance(value["publication_id"], str)
            and len(value["publication_id"]) == 32,
            "invalid_service_publication",
        )
        return cls(
            **{
                key: value[key]
                for key in (
                    "installation",
                    "issuer",
                    "template_id",
                    "native_key_id",
                    "publication_id",
                    "expires_at",
                    "token",
                )
            }
        )

    def acknowledge(
        self, path: Path, *, now: int | None = None, group: int | None = None
    ) -> None:
        """The consumer calls this only after a successful native request with token."""
        atomic_json(
            path,
            {
                "schema_version": 1,
                "kind": "atrium.litellm-service-key-ack",
                "installation": self.installation,
                "issuer": self.issuer,
                "template_id": self.template_id,
                "native_key_id": hashlib.sha256(self.token.encode()).hexdigest(),
                "publication_id": self.publication_id,
                "acknowledged_at": int(time.time()) if now is None else now,
            },
            mode=0o600 if group is None else 0o640,
            group=group,
        )


class Delivery:
    def __init__(self, controller, template_id: str):
        self.controller = controller
        self.template_id = template_id
        service = controller.desired.templates[template_id]["service"]
        config = controller.service_delivery.get(template_id, {})
        self.path = Path(service["runtime_key_path"])
        self.ack_path = Path(config.get("ack_path", str(self.path) + ".ack"))
        self.consumer_uid = config.get("consumer_uid", os.geteuid())
        self.group = config.get("consumer_gid")
        self.ack_timeout = config.get("ack_timeout_seconds", 60)
        require(
            integer(self.ack_timeout)
            and self.ack_timeout <= 300
            and integer(self.consumer_uid, minimum=0)
            and (self.group is None or integer(self.group, minimum=0)),
            "invalid_delivery_configuration",
        )
        require(self.path != self.ack_path, "publication_ack_path_collision")

    def publish(self, key: ServiceKey) -> None:
        atomic_json(
            self.path,
            key.document(),
            secret=True,
            mode=0o600 if self.group is None else 0o640,
            group=self.group,
        )

    def read(self, slot: dict, now: int) -> ServiceKey:
        key = ServiceKey.read(self.path, owner_uid=os.geteuid(), now=now)
        require(
            key.installation == self.controller.ledger.installation
            and key.issuer == self.controller.ledger.issuer
            and key.template_id == self.template_id
            and key.native_key_id == slot["native_key_id"]
            and key.publication_id == slot["publication_id"],
            "service_publication_identity_mismatch",
        )
        return key

    def acknowledged(self, slot: dict, now: int, *, missing_ok: bool = False) -> bool:
        if missing_ok and not self.ack_path.exists():
            return False
        ack = read_json(self.ack_path, uid=self.consumer_uid)
        fields(
            ack,
            {
                "schema_version",
                "kind",
                "installation",
                "issuer",
                "template_id",
                "native_key_id",
                "publication_id",
                "acknowledged_at",
            },
            "invalid_service_ack",
        )
        require(
            ack["schema_version"] == 1
            and ack["kind"] == "atrium.litellm-service-key-ack"
            and ack["installation"] == self.controller.ledger.installation
            and ack["issuer"] == self.controller.ledger.issuer
            and ack["template_id"] == self.template_id,
            "service_ack_identity_mismatch",
        )
        if (
            ack["native_key_id"] != slot["native_key_id"]
            or ack["publication_id"] != slot["publication_id"]
        ):
            # An old acknowledgement is expected while the running service has not read the replacement.
            previous = self.controller.ledger.state["services"][self.template_id].get(
                "current"
            )
            if (
                missing_ok
                and previous
                and ack["native_key_id"] == previous["native_key_id"]
                and ack["publication_id"] == previous["publication_id"]
            ):
                return False
            raise ControllerError("service_ack_identity_mismatch")
        require(
            integer(ack["acknowledged_at"])
            and slot["created_at"] <= ack["acknowledged_at"] <= now + 5,
            "service_ack_time_mismatch",
        )
        return True


class Rotator:
    def __init__(self, controller):
        self.controller = controller
        self.ledger = controller.ledger
        self.native = controller.native
        require(
            self.ledger._locked and not self.ledger.dry_run, "rotation_write_forbidden"
        )

    def _verify_live(self, slot: dict, delivery: Delivery, now: int) -> dict:
        key = delivery.read(slot, now)
        row = self.ledger.state["keys"][key.native_key_id]
        ceiling = self.controller.desired.key_ceiling(
            row["association"], self.ledger.state["teams"], source="controller", now=now
        )
        require(
            ceiling is not None and not row.get("retired"), "service_key_not_authorized"
        )
        verify_key(
            self.native.key(key.native_key_id), row["association"], ceiling, now=now
        )
        return ceiling

    def _mint(self, template_id: str, slot: dict, delivery: Delivery, now: int) -> dict:
        template = self.controller.desired.templates[template_id]
        team = self.ledger.state["teams"][template["team"]]
        raw_key = "sk-" + secrets.token_urlsafe(36)
        identity = hashlib.sha256(raw_key.encode()).hexdigest()
        record = {
            "issuer": self.ledger.issuer,
            "credential_id": identity,
            "native_key_id": identity,
            "principal_id": template["service"]["principal"],
            "authority_id": "controller",
            "domain": template["domain"],
            "template_id": template_id,
            "native_team_id": team["native_id"],
            "issued_at": now,
            "expires_at": now + template["max_lifetime_seconds"],
            "device_id": None,
            "state": "active",
            "effective_limits": {
                key: template[key] for key in ("models", "routes", "budget")
            },
        }
        pending = {
            "native_key_id": identity,
            "publication_id": uuid.uuid4().hex,
            "created_at": now,
            "deadline": now + delivery.ack_timeout,
            "published": False,
        }
        slot["pending"] = pending
        self.ledger.state["keys"][identity] = {
            "source": "controller",
            "association": record,
        }
        self.ledger.save()
        ceiling = self.controller.desired.key_ceiling(
            record, self.ledger.state["teams"], source="controller", now=now
        )
        require(ceiling is not None, "service_key_not_authorized")
        generated = self.native.generate(raw_key, record, ceiling, now=now)
        actual_expiry = expiration(generated["expires"])
        record["expires_at"] = actual_expiry
        ceiling["expires_at"] = actual_expiry
        self.native.call(
            "POST",
            "/key/update",
            {"key": identity, "metadata": metadata(record, actual_expiry)},
        )
        verify_key(self.native.key(identity), record, ceiling, now=now)
        self.ledger.save()
        self.controller.publish_service_associations(now)
        delivery.publish(
            ServiceKey(
                self.ledger.installation,
                self.ledger.issuer,
                template_id,
                identity,
                pending["publication_id"],
                actual_expiry,
                raw_key,
            )
        )
        pending["published"] = True
        self.ledger.save()
        return {"template": template_id, "status": "awaiting-acknowledgement"}

    def _tick(self, template_id: str, now: int) -> dict:
        template = self.controller.desired.templates[template_id]
        service = template["service"]
        delivery = Delivery(self.controller, template_id)
        slot = self.ledger.state["services"].setdefault(
            template_id,
            {
                "current": None,
                "previous": None,
                "pending": None,
                "last_rotation": 0,
            },
        )
        pending = slot["pending"]
        if pending:
            if not pending["published"]:
                if delivery.path.exists():
                    key = ServiceKey.read(
                        delivery.path, owner_uid=os.geteuid(), now=now
                    )
                    if (
                        key.native_key_id == pending["native_key_id"]
                        and key.publication_id == pending["publication_id"]
                    ):
                        pending["published"] = True
                        self.ledger.save()
                if not pending["published"]:
                    # Recovery after issuance/publication failure. The unpublished raw key is
                    # deliberately not recoverable from the ledger and is never re-exposed.
                    try:
                        self.native.key(pending["native_key_id"])
                    except NativeError as exc:
                        if exc.status != 404:
                            raise
                    else:
                        self.native.block(pending["native_key_id"])
                    self.ledger.state["keys"][pending["native_key_id"]]["retired"] = (
                        True
                    )
                    slot["pending"] = None
                    self.ledger.save()
                    return {
                        "template": template_id,
                        "status": "unpublished-key-retired",
                    }
            self._verify_live(pending, delivery, now)
            if not delivery.acknowledged(pending, now, missing_ok=True):
                require(now < pending["deadline"], "service_ack_timeout")
                return {"template": template_id, "status": "awaiting-acknowledgement"}
            if slot["current"]:
                slot["previous"] = {
                    "native_key_id": slot["current"]["native_key_id"],
                    "retire_at": now + service["overlap_seconds"],
                }
            slot["current"] = {
                key: pending[key]
                for key in ("native_key_id", "publication_id", "created_at")
            }
            slot["last_rotation"] = now
            slot["pending"] = None
            self.ledger.save()
            return {"template": template_id, "status": "acknowledged"}
        if slot["current"]:
            self._verify_live(slot["current"], delivery, now)
            delivery.acknowledged(slot["current"], now)
        else:
            require(not delivery.path.exists(), "unowned_service_publication")
        if slot["previous"]:
            if now < slot["previous"]["retire_at"]:
                return {"template": template_id, "status": "overlap"}
            previous = slot["previous"]["native_key_id"]
            require(
                previous != slot["current"]["native_key_id"],
                "service_rotation_identity_collision",
            )
            self.native.block(previous)
            self.ledger.state["keys"][previous]["retired"] = True
            slot["previous"] = None
            self.ledger.save()
            return {"template": template_id, "status": "previous-key-retired"}
        if (
            not slot["current"]
            or now >= slot["last_rotation"] + service["rotation_interval_seconds"]
        ):
            return self._mint(template_id, slot, delivery, now)
        return {"template": template_id, "status": "current"}

    def tick(self, now: int) -> list[dict]:
        return [
            self._tick(name, now)
            for name, template in self.controller.desired.templates.items()
            if template["credential_kind"] == "service"
        ]
