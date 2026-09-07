from pathlib import Path
from typing import Annotated, Literal

from atrium_profiles.models import (
    CredentialId,
    DomainId,
    IdentityId,
    ResourceId,
    ResourceURI,
    StrictModel,
)
from atrium_resolver.policy import VersionOne
from atrium_resolver.policy_schema import Budget, INFERENCE_ROUTES
from pydantic import Field, model_validator

Epoch = Annotated[int, Field(ge=0, le=2**53 - 1)]
Generation = Annotated[int, Field(ge=1, le=2**53 - 1)]
Digest = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]


class AdmissionError(Exception):
    def __init__(self, code: str, status: int = 403):
        super().__init__(code)
        self.code, self.status = code, status


class Producer(StrictModel):
    id: IdentityId
    kind: Literal["resolver", "controller-service"]
    path: Path
    publisher_uid: Annotated[int, Field(ge=0)]


class Settings(StrictModel):
    schema_version: VersionOne
    isolated: Literal[True]
    installation: ResourceId
    issuer: ResourceURI
    runtime_directory: Path
    policy_path: Path
    policy_publisher_uid: Annotated[int, Field(ge=0)]
    producers: tuple[Producer, ...]
    deny_issuer: ResourceURI
    deny_url: ResourceURI
    jwks_url: ResourceURI
    poll_seconds: Annotated[int, Field(ge=1, le=20)] = 20
    fetch_timeout_seconds: Annotated[int, Field(ge=1, le=5)] = 5

    @model_validator(mode="after")
    def configured_trust(self):
        if (
            not self.producers
            or len({p.id for p in self.producers}) != len(self.producers)
            or len({p.path for p in self.producers}) != len(self.producers)
            or any(
                not path.is_absolute()
                for path in (
                    self.runtime_directory,
                    self.policy_path,
                    *(p.path for p in self.producers),
                )
            )
        ):
            raise ValueError("Invalid admission trust configuration")
        return self


class Credential(StrictModel):
    issuer: ResourceURI
    credential_id: CredentialId
    native_key_id: Digest
    principal: IdentityId
    authority: IdentityId
    domain: DomainId
    instance: ResourceId
    target: ResourceURI
    audience: Annotated[str, Field(min_length=1, max_length=2048)]
    template_id: ResourceId
    team_id: Annotated[str, Field(min_length=1, max_length=160)]
    issued_at: Epoch
    expires_at: Epoch
    device_id: ResourceId | None
    admin_outage_eligible: bool
    models: tuple[ResourceId, ...]
    routes: tuple[str, ...]
    budget: Budget
    operation_id: Digest | None
    status: Literal[
        "reserved", "prepared", "delivering", "delivered", "cleanup", "revoked"
    ]

    @model_validator(mode="after")
    def exact_limits(self):
        if (
            self.credential_id != "sha256:" + self.native_key_id
            or self.issued_at >= self.expires_at
            or not self.models
            or not self.routes
            or len(set(self.models)) != len(self.models)
            or len(set(self.routes)) != len(self.routes)
            or not set(self.routes) <= INFERENCE_ROUTES
        ):
            raise ValueError("Invalid protected credential")
        return self


class ResolverPublication(StrictModel):
    schema_version: VersionOne
    kind: Literal["atrium.litellm-admission-associations"]
    issuer: ResourceURI
    installation: ResourceId
    generation: Generation
    issued_at: Epoch
    credentials: tuple[Credential, ...]
