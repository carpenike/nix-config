import re
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .errors import require
from .files import digest, read_json

IDENTITY = re.compile(r"[a-z][a-z0-9_-]{0,63}")
HASH = re.compile(r"[0-9a-f]{64}")
DOMAIN = re.compile(r"[a-z][a-z0-9_-]*:[a-z][a-z0-9_-]*")
ROUTES = frozenset(
    {
        "/chat/completions",
        "/v1/chat/completions",
        "/completions",
        "/v1/completions",
        "/embeddings",
        "/v1/embeddings",
        "/responses",
        "/v1/responses",
        "/messages",
        "/v1/messages",
        "/anthropic/v1/messages",
    }
)


def fields(
    value: object, names: set[str], code: str = "invalid_association_fields"
) -> None:
    require(isinstance(value, dict) and set(value) == names, code)


def integer(value: object, *, minimum: int = 1) -> bool:
    return type(value) is int and value >= minimum


def identifier(value: object) -> bool:
    return isinstance(value, str) and IDENTITY.fullmatch(value) is not None


def logical_id(value: object) -> bool:
    return (
        isinstance(value, str)
        and re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._:-]{0,159}", value) is not None
    )


def strings(value: object) -> bool:
    return (
        isinstance(value, list)
        and bool(value)
        and all(isinstance(item, str) and item for item in value)
        and len(value) == len(set(value))
    )


def limits(value: dict) -> dict:
    fields(value, {"models", "routes", "budget"})
    require(
        strings(value["models"]) and all(logical_id(m) for m in value["models"]),
        "invalid_model_limits",
    )
    require(
        strings(value["routes"]) and set(value["routes"]) <= ROUTES,
        "invalid_route_limits",
    )
    budget = value["budget"]
    fields(budget, {"usd", "duration_seconds"})
    require(
        type(budget["usd"]) in (float, int)
        and 0 < budget["usd"] < float("inf")
        and integer(budget["duration_seconds"]),
        "invalid_budget_limits",
    )
    return value


ASSOCIATION_FIELDS = {
    "issuer",
    "credential_id",
    "native_key_id",
    "principal_id",
    "authority_id",
    "domain",
    "template_id",
    "native_team_id",
    "issued_at",
    "expires_at",
    "device_id",
    "state",
    "effective_limits",
}


def association(value: dict, issuer: str) -> dict:
    fields(value, ASSOCIATION_FIELDS)
    require(value["issuer"] == issuer, "association_issuer_mismatch")
    require(
        isinstance(value["credential_id"], str)
        and HASH.fullmatch(value["credential_id"])
        and value["native_key_id"] == value["credential_id"],
        "invalid_native_key_identity",
    )
    require(
        identifier(value["principal_id"]) and identifier(value["authority_id"]),
        "invalid_principal_binding",
    )
    require(
        isinstance(value["domain"], str) and DOMAIN.fullmatch(value["domain"]),
        "invalid_domain",
    )
    require(
        logical_id(value["template_id"]) and logical_id(value["native_team_id"]),
        "invalid_native_binding",
    )
    require(
        integer(value["issued_at"])
        and integer(value["expires_at"])
        and value["issued_at"] < value["expires_at"],
        "invalid_association_lifetime",
    )
    require(
        value["device_id"] is None or identifier(value["device_id"]),
        "invalid_device_binding",
    )
    require(value["state"] in ("active", "revoked"), "invalid_association_state")
    limits(value["effective_limits"])
    return value


@dataclass(frozen=True)
class Snapshot:
    document: dict
    sha256: str

    @property
    def records(self) -> dict[str, dict]:
        return {item["native_key_id"]: item for item in self.document["associations"]}

    @classmethod
    def parse(
        cls, value: dict, *, installation: str, issuer: str, now: int
    ) -> "Snapshot":
        fields(
            value,
            {
                "schema_version",
                "kind",
                "installation",
                "issuer",
                "generation",
                "generated_at",
                "expires_at",
                "associations",
            },
            "invalid_snapshot_fields",
        )
        require(
            value["schema_version"] == 1
            and type(value["schema_version"]) is int
            and value["kind"] == "atrium.litellm-associations",
            "unsupported_snapshot",
        )
        require(
            value["installation"] == installation and value["issuer"] == issuer,
            "snapshot_installation_mismatch",
        )
        require(integer(value["generation"]), "invalid_snapshot_generation")
        require(
            integer(value["generated_at"])
            and integer(value["expires_at"])
            and value["generated_at"] <= now + 5
            and value["generated_at"]
            < value["expires_at"]
            <= value["generated_at"] + 300
            and now < value["expires_at"],
            "snapshot_not_fresh",
        )
        require(isinstance(value["associations"], list), "invalid_snapshot_records")
        seen = set()
        for item in value["associations"]:
            association(item, issuer)
            require(item["native_key_id"] not in seen, "duplicate_native_key")
            require(
                item["issued_at"] <= value["generated_at"] + 5, "future_association"
            )
            seen.add(item["native_key_id"])
        return cls(value, digest(value))


class AssociationSource(Protocol):
    def read(self, now: int) -> Snapshot: ...


@dataclass(frozen=True)
class ProtectedSnapshotSource:
    path: Path
    installation: str
    issuer: str
    publisher_uid: int

    def read(self, now: int) -> Snapshot:
        return Snapshot.parse(
            read_json(self.path, uid=self.publisher_uid),
            installation=self.installation,
            issuer=self.issuer,
            now=now,
        )
