import json

from atrium_resolver.litellm_inventory import AssociationPublication

from .models import AdmissionError, Credential, ResolverPublication
from .state import canonical, fingerprint, protected_document


def _validate_binding(record, settings, policy, *, service):
    principal = policy.principals.get(record.principal)
    template = policy.model_templates.get(record.template_id)
    instance = policy.instances.get(record.instance)
    if (
        record.issuer != settings.issuer
        or principal is None
        or template is None
        or instance is None
        or template.instance != record.instance
        or instance.domain != record.domain
        or instance.target != record.target
        or instance.audience != record.audience
        or template.domain != record.domain
    ):
        raise AdmissionError("association_target_invalid")
    if service:
        if (
            principal.kind != "service"
            or template.credential_kind != "service"
            or template.service.principal != record.principal
            or record.authority != "controller"
            or record.admin_outage_eligible
        ):
            raise AdmissionError("service_provenance_invalid")
    elif (
        principal.kind != "human"
        or template.credential_kind != "client"
        or record.authority == "controller"
        or record.authority not in policy.authorities
        or record.authority not in instance.authority_binding
    ):
        raise AdmissionError("human_provenance_invalid")


def read_producer(producer, settings, policy, now):
    raw = protected_document(producer.path, producer.publisher_uid)
    records = []
    if producer.kind == "resolver":
        envelope = ResolverPublication.model_validate_json(canonical(raw))
        generation, issued_at = envelope.generation, envelope.issued_at
        records = list(envelope.credentials)
    else:
        envelope = AssociationPublication.model_validate_json(canonical(raw))
        generation, issued_at = envelope.generation, envelope.generated_at
        if (
            not issued_at < envelope.expires_at <= issued_at + 300
            or now >= envelope.expires_at
        ):
            raise AdmissionError("service_producer_stale")
        for row in envelope.associations:
            template = policy.model_templates.get(row.template_id)
            instance = (
                None if template is None else policy.instances.get(template.instance)
            )
            if instance is None:
                raise AdmissionError("service_target_unknown")
            if row.native_key_id != row.credential_id:
                raise AdmissionError("service_credential_identity_invalid")
            records.append(
                Credential(
                    issuer=row.issuer,
                    credential_id="sha256:" + row.native_key_id,
                    native_key_id=row.native_key_id,
                    principal=row.principal_id,
                    authority=row.authority_id,
                    domain=row.domain,
                    instance=template.instance,
                    target=instance.target,
                    audience=instance.audience,
                    template_id=row.template_id,
                    team_id=row.native_team_id,
                    issued_at=row.issued_at,
                    expires_at=row.expires_at,
                    device_id=row.device_id,
                    admin_outage_eligible=False,
                    models=row.effective_limits.models,
                    routes=row.effective_limits.routes,
                    budget=row.effective_limits.budget,
                    operation_id=None,
                    status="prepared" if row.state == "active" else "revoked",
                )
            )
    if (
        envelope.installation != settings.installation
        or envelope.issuer != settings.issuer
        or issued_at > now + 5
        or issued_at < 0
    ):
        raise AdmissionError("producer_context_invalid")
    seen = set()
    for record in records:
        if record.native_key_id in seen or record.issued_at > issued_at + 5:
            raise AdmissionError("producer_identity_invalid")
        seen.add(record.native_key_id)
        _validate_binding(
            record, settings, policy, service=producer.kind == "controller-service"
        )
    return generation, issued_at, fingerprint(raw), records


def ingest(state, producer, candidate):
    generation, issued_at, digest, records = candidate
    previous = state["producers"].get(producer.id)
    if previous is not None and (
        generation < previous["generation"]
        or issued_at < previous["issued_at"]
        or generation == previous["generation"]
        and digest != previous["digest"]
    ):
        raise AdmissionError("producer_rollback_or_equivocation")
    pending = {}
    for record in records:
        key = record.native_key_id
        entry = record.model_dump(mode="json")
        old = state["history"].get(key)
        if old is not None:
            prior = Credential.model_validate_json(json.dumps(old["record"]))
            if (
                old["producer"] != producer.id
                or record.expires_at > prior.expires_at
                or any(
                    entry[name] != old["record"][name]
                    for name in entry
                    if name not in ("status", "expires_at")
                )
                or prior.status in ("cleanup", "revoked")
                and record.status not in ("cleanup", "revoked")
            ):
                raise AdmissionError("association_rebound_or_revived")
        pending[key] = {"producer": producer.id, "record": entry, "present": True}
    for key, row in state["history"].items():
        if row["producer"] == producer.id and key not in pending:
            row["present"] = False
    state["history"].update(pending)
    state["producers"][producer.id] = {
        "generation": generation,
        "issued_at": issued_at,
        "digest": digest,
    }
