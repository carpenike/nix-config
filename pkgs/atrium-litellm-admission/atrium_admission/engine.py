import json

from atrium_profiles import ProfileError
from atrium_profiles.models import AuthorizationContext, IssuerQualifiedCredential
from atrium_profiles.runtime import DurableAlertLog
from atrium_resolver.policy_schema import PolicyDocument

from .feed import Feed, verified_cache
from .models import AdmissionError, Credential
from .producers import ingest, read_producer
from .state import State, protected_document


class Admission:
    def __init__(self, settings, *, start_poller=True):
        self.settings = settings
        self.store = State(settings)
        self.alerts = DurableAlertLog(settings.runtime_directory / "alerts")
        self.feed = Feed(settings, self.store)
        with self.store.transaction():
            pass
        if start_poller:
            self.feed.start()

    def close(self):
        self.feed.close()

    def policy(self):
        path = self.settings.policy_path
        if path.resolve().is_relative_to("/nix/store"):
            with path.open("rb") as stream:
                value = stream.read(8 * 1024 * 1024 + 1)
            if len(value) > 8 * 1024 * 1024:
                raise AdmissionError("policy_unavailable", 503)
            return PolicyDocument.model_validate_json(value)
        return PolicyDocument.model_validate_json(
            json.dumps(protected_document(path, self.settings.policy_publisher_uid))
        )

    def admit(self, key_hash, native_team, model, path):
        from .models import Digest
        from pydantic import TypeAdapter

        TypeAdapter(Digest).validate_python(key_hash, strict=True)
        self.feed.poll()
        with self.store.transaction() as state:
            now = self.store.advance_clock(state)
            policy = self.policy()
            errors = {}
            for producer in self.settings.producers:
                try:
                    candidate = read_producer(producer, self.settings, policy, now)
                    ingest(state, producer, candidate)
                except Exception:
                    errors[producer.id] = "producer_unavailable"
            stored = state["history"].get(key_hash)
            if errors:
                raise AdmissionError(
                    "owned_authorization_unavailable"
                    if stored is not None
                    else "ownership_unverified",
                    503,
                )
            if stored is None:
                return "verified-non-owned"
            if stored["producer"] in errors or not stored["present"]:
                raise AdmissionError("owned_authorization_unavailable")
            record = Credential.model_validate_json(json.dumps(stored["record"]))
            producer = next(
                p for p in self.settings.producers if p.id == stored["producer"]
            )
            principal = policy.principals.get(record.principal)
            template = policy.model_templates.get(record.template_id)
            instance = policy.instances.get(record.instance)
            if (
                record.status not in ("prepared", "delivering", "delivered")
                or not record.issued_at <= now < record.expires_at
                or principal is None
                or principal.status != "active"
                or template is None
                or template.status != "active"
                or instance is None
                or instance.status != "active"
                or record.target != instance.target
                or record.audience != instance.audience
                or record.instance != template.instance
                or record.domain != template.domain
                or record.domain != instance.domain
                or record.team_id != native_team
                or record.expires_at - record.issued_at > template.max_lifetime_seconds
                or model not in record.models
                or model not in template.models
                or path not in record.routes
                or path not in template.routes
                or record.budget.duration_seconds != template.budget.duration_seconds
                or record.budget.usd > template.budget.usd
            ):
                raise AdmissionError("owned_request_not_permitted")
            allowlist = policy.principal_model_allowlists.get(record.principal, {}).get(
                record.domain
            )
            if (
                record.principal not in policy.potential_members(instance.acl)
                or record.principal not in policy.potential_members(template.acl)
                or allowlist is None
                or record.template_id not in allowlist.templates
                or model not in allowlist.models
            ):
                raise AdmissionError("owned_request_not_permitted")
            service = producer.kind == "controller-service"
            if service:
                if (
                    principal.kind != "service"
                    or record.authority != "controller"
                    or template.credential_kind != "service"
                    or template.service.principal != record.principal
                    or record.admin_outage_eligible
                ):
                    raise AdmissionError("service_provenance_invalid")
            elif (
                principal.kind != "human"
                or template.credential_kind != "client"
                or record.authority == "controller"
                or record.authority not in instance.authority_binding
                or policy.authorities[record.authority].status != "active"
                or not any(
                    binding.authority == record.authority
                    for binding in principal.bindings
                )
            ):
                raise AdmissionError("human_provenance_invalid")
            if record.device_id is not None:
                device = policy.devices.get(record.device_id)
                if (
                    device is None
                    or device.status != "active"
                    or record.principal not in device.principals
                    or record.domain not in device.domains
                ):
                    raise AdmissionError("device_not_permitted")
            if (
                instance.device_acl.mode == "required"
                and record.device_id not in instance.device_acl.devices
            ):
                raise AdmissionError("device_required")
            admin = (
                not service
                and record.admin_outage_eligible
                and "admin" in principal.roles
            )
            context = AuthorizationContext(
                profile="native-key",
                principal=record.principal,
                authority=record.authority,
                domain=record.domain,
                instance_id=record.instance,
                view_id=record.instance,
                target=record.target,
                permissions=frozenset(),
                scopes=frozenset(),
                device=record.device_id,
                credential=IssuerQualifiedCredential(
                    record.issuer, record.credential_id
                ),
                issued_at=record.issued_at,
                expires_at=record.expires_at,
                verified_admin=admin,
                admin_outage_eligible=admin,
                native_identity=None,
            )
            cache = verified_cache(self.settings, state, now)
            try:
                return cache.require_admission(
                    context, now=now, emit_alert=self.alerts.emit
                )
            except ProfileError:
                raise
