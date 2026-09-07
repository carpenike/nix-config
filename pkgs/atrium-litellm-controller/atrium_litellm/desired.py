from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

from .associations import DOMAIN, integer, limits, logical_id, strings
from .errors import require
from .files import decode


def active(table: dict) -> dict:
    return {name: row for name, row in table.items() if row.get("status") == "active"}


@dataclass(frozen=True)
class Desired:
    document: dict

    @classmethod
    def read(cls, path: Path) -> "Desired":
        return cls.parse(decode(path.read_bytes()))

    @classmethod
    def parse(cls, value: dict) -> "Desired":
        require(
            value.get("schema_version") == 2
            and type(value.get("schema_version")) is int
            and value.get("kind") == "atrium.litellm"
            and value.get("phase") == 1
            and value.get("environment") == "isolated"
            and value.get("native_version") == "v1.99.1",
            "unsupported_desired_state",
        )
        require(
            value.get("inference_management_routes") == "deny"
            and value.get("model_routing") == {"cross_provider_fallback": False}
            and value.get("removed_templates") == "disable-owned-keys"
            and value.get("authorized_runtime_keys") == "retain",
            "unsafe_desired_policy",
        )
        ownership = value.get("ownership", {})
        require(
            ownership.get("strategy") == "authoritative-inventory"
            and ownership.get("owner") == "command-center"
            and ownership.get("require_native_credential_association") is True
            and ownership.get("unowned_objects") == "leave-unchanged",
            "unsafe_ownership_policy",
        )
        for name in (
            "teams",
            "aliases",
            "model_backends",
            "model_templates",
            "providers",
            "service_credentials",
            "principals",
            "authorities",
            "instances",
            "domains",
            "devices",
            "principal_model_allowlists",
        ):
            require(isinstance(value.get(name), dict), "missing_desired_table")
        for name in (
            "teams",
            "aliases",
            "model_backends",
            "model_templates",
            "providers",
            "service_credentials",
            "principals",
            "authorities",
            "instances",
            "domains",
            "devices",
        ):
            require(
                all(
                    logical_id(key)
                    and isinstance(row, dict)
                    and row.get("status") in ("active", "retired")
                    for key, row in value[name].items()
                ),
                "invalid_desired_record",
            )
        result = cls(value)
        domains = active(value["domains"])
        require(
            all(DOMAIN.fullmatch(domain) for domain in domains),
            "invalid_desired_domain",
        )
        for team in result.teams.values():
            require(
                team.get("owner") == "command-center"
                and team.get("domain") in domains
                and strings(team.get("models"))
                and set(team["models"]) <= result.aliases.keys(),
                "invalid_desired_team",
            )
        for name, alias in result.aliases.items():
            require(
                alias.get("owner") == "command-center"
                and alias.get("team") in result.teams
                and alias.get("domain") == result.teams[alias["team"]]["domain"]
                and strings(alias.get("backends"))
                and alias.get("fallbacks") == [],
                "invalid_desired_alias",
            )
            require(
                name in result.teams[alias["team"]]["models"], "alias_team_mismatch"
            )
            for backend_id in alias["backends"]:
                backend = active(value["model_backends"]).get(backend_id)
                require(
                    backend is not None and backend.get("domain") == alias["domain"],
                    "foreign_alias_backend",
                )
                credential = active(value["service_credentials"]).get(
                    backend.get("credential")
                )
                provider = active(value["providers"]).get(backend.get("provider"))
                require(
                    credential is not None
                    and provider is not None
                    and all(
                        credential.get(field) == backend.get(field)
                        for field in ("provider", "domain", "account")
                    )
                    and isinstance(backend.get("model"), str)
                    and "/" in backend["model"]
                    and "*" not in backend["model"],
                    "foreign_backend_account",
                )
        for name, template in result.templates.items():
            limits(
                {field: template.get(field) for field in ("models", "routes", "budget")}
            )
            require(
                template.get("team") in result.teams
                and template.get("domain") == result.teams[template["team"]]["domain"]
                and set(template["models"])
                <= set(result.teams[template["team"]]["models"])
                and all(
                    result.aliases[m]["team"] == template["team"]
                    for m in template["models"]
                ),
                "invalid_template_team",
            )
            instance = active(value["instances"]).get(template.get("instance"), {})
            require(
                instance.get("adapter") == "litellm"
                and instance.get("domain") == template["domain"]
                and name in instance.get("model_templates", []),
                "invalid_template_instance",
            )
            lifetime = template.get("max_lifetime_seconds")
            require(integer(lifetime), "invalid_template_lifetime")
            if template.get("credential_kind") == "client":
                require(
                    lifetime <= 3600 and template.get("service") is None,
                    "invalid_client_template",
                )
            else:
                require(
                    template.get("credential_kind") == "service"
                    and isinstance(template.get("service"), dict),
                    "invalid_service_template",
                )
                service = template["service"]
                principal = active(value["principals"]).get(
                    service.get("principal"), {}
                )
                require(
                    principal.get("kind") == "service"
                    and principal.get("roles") == []
                    and integer(service.get("rotation_interval_seconds"))
                    and integer(service.get("overlap_seconds"))
                    and lifetime
                    > service["rotation_interval_seconds"] + service["overlap_seconds"]
                    and isinstance(service.get("runtime_key_path"), str)
                    and service["runtime_key_path"].startswith("/run/"),
                    "invalid_service_rotation",
                )
        return result

    @property
    def teams(self) -> dict:
        return active(self.document["teams"])

    @property
    def aliases(self) -> dict:
        return active(self.document["aliases"])

    @property
    def templates(self) -> dict:
        return active(self.document["model_templates"])

    def runtime_binding(self, backend_id: str, bindings: dict) -> dict:
        backend = self.document["model_backends"][backend_id]
        binding = bindings.get(backend_id)
        require(
            isinstance(binding, dict) and set(binding) == {"api_base"},
            "missing_backend_transport",
        )
        origin = urlsplit(binding["api_base"])
        provider = self.document["providers"][backend["provider"]]
        require(
            origin.scheme in ("https", "http")
            and origin.hostname in provider["egress_hosts"]
            and not origin.username
            and not origin.password
            and not origin.query
            and not origin.fragment,
            "unsafe_backend_transport",
        )
        return binding

    def key_ceiling(
        self, record: dict, teams: dict, *, source: str, now: int
    ) -> dict | None:
        template = self.templates.get(record["template_id"])
        if (
            template is None
            or record["state"] != "active"
            or record["expires_at"] <= now
        ):
            return None
        team = teams.get(template["team"])
        if (
            not team
            or team["status"] != "owned"
            or record["native_team_id"] != team["native_id"]
        ):
            return None
        if record["domain"] != template["domain"]:
            return None
        principal = active(self.document["principals"]).get(record["principal_id"], {})
        if not principal:
            return None
        if source == "controller":
            if (
                template["credential_kind"] != "service"
                or record["principal_id"] != template["service"]["principal"]
            ):
                return None
        else:
            if template["credential_kind"] != "client":
                return None
            instance = self.document["instances"][template["instance"]]
            if record["authority_id"] not in instance["authority_binding"]:
                return None
            if not any(
                b["authority"] == record["authority_id"]
                for b in principal.get("bindings", [])
            ):
                return None
            eligible = (
                self.document["principal_model_allowlists"]
                .get(record["principal_id"], {})
                .get(record["domain"], {})
            )
            if record["template_id"] not in eligible.get("templates", []):
                return None
            device_acl = instance["device_acl"]
            if (
                device_acl["mode"] == "required"
                and record["device_id"] not in device_acl["devices"]
            ):
                return None
            if record["device_id"] is not None:
                device = active(self.document["devices"]).get(record["device_id"], {})
                if record["principal_id"] not in device.get("principals", []) or record[
                    "domain"
                ] not in device.get("domains", []):
                    return None
        effective = record["effective_limits"]
        models = sorted(
            set(effective["models"])
            & set(template["models"])
            & set(self.teams[template["team"]]["models"])
        )
        routes = sorted(set(effective["routes"]) & set(template["routes"]))
        if (
            not models
            or not routes
            or effective["budget"]["duration_seconds"]
            != template["budget"]["duration_seconds"]
        ):
            return None
        expires = min(
            record["expires_at"], record["issued_at"] + template["max_lifetime_seconds"]
        )
        if expires <= now:
            return None
        return {
            "models": models,
            "routes": routes,
            "expires_at": expires,
            "budget": {
                "usd": min(effective["budget"]["usd"], template["budget"]["usd"]),
                "duration_seconds": template["budget"]["duration_seconds"],
            },
        }
