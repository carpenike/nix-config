import copy
import fnmatch
import time
import uuid
from pathlib import Path

from .associations import AssociationSource
from .desired import Desired
from .errors import ControllerError, require
from .files import atomic_json, digest, read_bytes
from .ledger import Ledger
from .native import (
    EMPTY_OBJECT_PERMISSIONS,
    Native,
    NativeError,
    SAFE_ROUTER,
    expiration,
    permissions,
    verify_key,
)


def native_id() -> str:
    return "atrium-" + uuid.uuid4().hex


def read_provider_credential(_name: str, declaration: dict) -> str:
    value = (
        read_bytes(Path(declaration["runtime_path"]), secret=True, limit=16384)
        .decode()
        .strip()
    )
    require(
        bool(value) and "\n" not in value and "\r" not in value,
        "invalid_provider_credential",
    )
    return value


class Controller:
    def __init__(
        self,
        desired: Desired,
        ledger: Ledger,
        native: Native,
        associations: AssociationSource,
        backend_transports: dict,
        *,
        credential_reader=read_provider_credential,
        service_delivery: dict | None = None,
        service_association_snapshot: Path | None = None,
        bindings_snapshot: Path | None = None,
    ):
        self.desired = desired
        self.ledger = ledger
        self.native = native
        self.associations = associations
        self.backend_transports = backend_transports
        self.credential_reader = credential_reader
        self.service_delivery = {} if service_delivery is None else service_delivery
        self.service_association_snapshot = (
            service_association_snapshot or ledger.path / "service-associations.json"
        )
        self.bindings_snapshot = (
            bindings_snapshot or ledger.path / "native-bindings.json"
        )

    def publish_bindings(self, now: int) -> None:
        require(
            self.ledger._locked and not self.ledger.dry_run, "ledger_write_forbidden"
        )
        atomic_json(
            self.bindings_snapshot,
            {
                "schema_version": 1,
                "kind": "atrium.litellm-bindings",
                "installation": self.ledger.installation,
                "issuer": self.ledger.issuer,
                "generation": self.ledger.state["revision"],
                "generated_at": now,
                "expires_at": now + 300,
                "desired_state_sha256": digest(self.desired.document),
                "teams": {
                    name: {
                        "native_team_id": self.ledger.state["teams"][name]["native_id"],
                        "domain": row["domain"],
                        "models": row["models"],
                    }
                    for name, row in self.desired.teams.items()
                },
                "aliases": {
                    name: [
                        {
                            "native_model_id": row["native_id"],
                            "backend_id": row["backend"],
                            "model": row["expected"]["litellm_params"]["model"],
                            "api_base": row["expected"]["litellm_params"]["api_base"],
                            "native_credential_name": row["expected"]["litellm_params"][
                                "litellm_credential_name"
                            ],
                            "domain": row["expected"]["metadata"]["cc.domain"],
                            "provider": row["expected"]["metadata"]["cc.provider"],
                            "account": row["expected"]["metadata"]["cc.account"],
                            "credential_id": row["expected"]["metadata"][
                                "cc.credential"
                            ],
                        }
                        for row in self.ledger.state["aliases"].values()
                        if row["alias"] == name and row["status"] == "owned"
                    ]
                    for name in self.desired.aliases
                },
            },
        )

    def publish_service_associations(self, now: int) -> None:
        require(
            self.ledger._locked and not self.ledger.dry_run, "ledger_write_forbidden"
        )
        records = [
            {
                **row["association"],
                "state": "revoked"
                if row.get("retired")
                else row["association"]["state"],
            }
            for row in self.ledger.state["keys"].values()
            if row["source"] == "controller"
        ]
        atomic_json(
            self.service_association_snapshot,
            {
                "schema_version": 1,
                "kind": "atrium.litellm-associations",
                "installation": self.ledger.installation,
                "issuer": self.ledger.issuer,
                "generation": self.ledger.state["revision"],
                "generated_at": now,
                "expires_at": now + 300,
                "associations": records,
            },
        )

    def _credential_info(self, logical: str) -> dict:
        item = self.desired.document["service_credentials"][logical]
        return {
            "cc.installation": self.ledger.installation,
            "cc.credential": logical,
            "cc.domain": item["domain"],
            "cc.provider": item["provider"],
            "cc.account": item["account"],
        }

    def _alias_expected(self, alias: str, backend: str, credentials: dict) -> dict:
        item = self.desired.document["model_backends"][backend]
        binding = self.desired.runtime_binding(backend, self.backend_transports)
        return {
            "model_name": alias,
            "litellm_params": {
                "model": item["model"],
                "api_base": binding["api_base"],
                "litellm_credential_name": credentials[item["credential"]]["native_id"],
            },
            "metadata": {
                "cc.installation": self.ledger.installation,
                "cc.domain": item["domain"],
                "cc.backend": backend,
                "cc.provider": item["provider"],
                "cc.account": item["account"],
                "cc.credential": item["credential"],
            },
        }

    def _verify_alias(self, model: dict, row: dict) -> None:
        expected = row["expected"]
        require(
            model["model_info"].get("id") == row["native_id"]
            and model["model_name"] == expected["model_name"],
            "native_alias_identity_mismatch",
        )
        params = model["litellm_params"]
        require(
            all(
                params.get(key) == value
                for key, value in expected["litellm_params"].items()
            ),
            "native_alias_backend_drift",
        )
        require(
            all(
                model["model_info"].get(key) == value
                for key, value in expected["metadata"].items()
            ),
            "native_alias_account_drift",
        )
        require(
            not model["model_info"].get("team_id")
            and not any(
                params.get(k)
                for k in (
                    "model_list",
                    "fallbacks",
                    "default_fallbacks",
                    "model_group_alias",
                )
            ),
            "unsupported_alias_routing",
        )

    def _infrastructure_plan(self, state: dict) -> list[dict]:
        actions = []
        observed_models = self.native.models()
        observed_credentials = self.native.credentials()
        for alias_id, alias in self.desired.aliases.items():
            for backend_id in alias["backends"]:
                backend = self.desired.document["model_backends"][backend_id]
                self.desired.runtime_binding(backend_id, self.backend_transports)
                credential_id = backend["credential"]
                expected_info = self._credential_info(credential_id)
                if credential_id not in state["credentials"]:
                    row = {
                        "native_id": native_id(),
                        "provenance": "controller-created",
                        "status": "intent",
                        "expected": expected_info,
                    }
                    state["credentials"][credential_id] = row
                row = state["credentials"][credential_id]
                require(
                    row["expected"] == expected_info, "credential_replacement_required"
                )
                native_credential = observed_credentials.get(row["native_id"])
                if native_credential is None:
                    require(row["status"] == "intent", "owned_credential_missing")
                    if not any(
                        a.get("logical") == credential_id
                        and a["action"] == "create-credential"
                        for a in actions
                    ):
                        actions.append(
                            {
                                "action": "create-credential",
                                "logical": credential_id,
                                "record": row,
                            }
                        )
                else:
                    require(
                        native_credential.get("credential_info") == expected_info,
                        "native_account_binding_drift",
                    )
                    if row["status"] == "intent":
                        actions.append(
                            {
                                "action": "confirm-credential",
                                "logical": credential_id,
                                "record": row,
                            }
                        )
        for alias_id, alias in self.desired.aliases.items():
            wanted_keys = {alias_id + "::" + backend for backend in alias["backends"]}
            known = {
                key: row
                for key, row in state["aliases"].items()
                if row["alias"] == alias_id
            }
            require(set(known) <= wanted_keys, "exclusive_alias_replacement_required")
            for backend in alias["backends"]:
                key = alias_id + "::" + backend
                expected = self._alias_expected(alias_id, backend, state["credentials"])
                if key not in state["aliases"]:
                    state["aliases"][key] = {
                        "native_id": native_id(),
                        "alias": alias_id,
                        "backend": backend,
                        "status": "intent",
                        "provenance": "controller-created",
                        "expected": expected,
                    }
                row = state["aliases"][key]
                require(
                    row.get("pending_expected") in (None, expected),
                    "alias_update_incomplete",
                )
                if row["expected"] != expected:
                    require(
                        row["status"] == "owned"
                        and row["expected"]["metadata"]["cc.domain"]
                        == expected["metadata"]["cc.domain"],
                        "exclusive_alias_replacement_required",
                    )
                    row["pending_expected"] = expected
            owned_ids = {
                row["native_id"]
                for row in state["aliases"].values()
                if row["alias"] == alias_id
            }
            matches = [
                row
                for row in observed_models
                if fnmatch.fnmatchcase(alias_id, row["model_name"])
            ]
            require(
                all(
                    row["model_info"]["id"] in owned_ids
                    and row["model_name"] == alias_id
                    for row in matches
                ),
                "unowned_alias_collision",
            )
            require(
                len(matches) == len({row["model_info"]["id"] for row in matches}),
                "ambiguous_alias_identity",
            )
            for key in sorted(wanted_keys):
                row = state["aliases"][key]
                match = next(
                    (m for m in matches if m["model_info"]["id"] == row["native_id"]),
                    None,
                )
                if match is None:
                    require(row["status"] == "intent", "owned_alias_missing")
                    actions.append(
                        {"action": "create-alias", "logical": key, "record": row}
                    )
                else:
                    pending = row.get("pending_expected")
                    if pending:
                        try:
                            self._verify_alias(match, row)
                        except ControllerError:
                            self._verify_alias(match, {**row, "expected": pending})
                            row["expected"] = row.pop("pending_expected")
                            actions.append(
                                {
                                    "action": "confirm-alias",
                                    "logical": key,
                                    "record": row,
                                }
                            )
                        else:
                            actions.append(
                                {
                                    "action": "update-alias",
                                    "logical": key,
                                    "record": row,
                                }
                            )
                    else:
                        self._verify_alias(match, row)
                    if row["status"] == "intent":
                        actions.append(
                            {"action": "confirm-alias", "logical": key, "record": row}
                        )
        for logical, desired in self.desired.teams.items():
            if logical not in state["teams"]:
                state["teams"][logical] = {
                    "native_id": native_id(),
                    "domain": desired["domain"],
                    "status": "intent",
                    "provenance": "controller-created",
                }
                actions.append(
                    {
                        "action": "create-team",
                        "logical": logical,
                        "record": state["teams"][logical],
                    }
                )
                continue
            row = state["teams"][logical]
            require(row["domain"] == desired["domain"], "native_team_domain_changed")
            try:
                native = self.native.team(row["native_id"])
            except NativeError as exc:
                if exc.status == 404 and row["status"] == "intent":
                    actions.append(
                        {"action": "create-team", "logical": logical, "record": row}
                    )
                    continue
                raise
            self._verify_team_routing(native)
            if sorted(native.get("models") or []) != sorted(desired["models"]):
                actions.append(
                    {"action": "update-team", "logical": logical, "record": row}
                )
            elif row["status"] == "intent":
                actions.append(
                    {"action": "confirm-team", "logical": logical, "record": row}
                )
        return actions

    @staticmethod
    def _verify_team_routing(team: dict) -> None:
        model_table = team.get("litellm_model_table") or {}
        require(
            isinstance(model_table, dict)
            and model_table.get("model_aliases") in (None, {}, "{}"),
            "unowned_team_alias_override",
        )
        router = team.get("router_settings")
        require(
            router in (None, {})
            or (
                isinstance(router, dict)
                and all(router.get(k) == v for k, v in SAFE_ROUTER.items())
            ),
            "unsafe_team_router",
        )
        require(not team.get("access_group_models"), "unowned_team_access_group")

    def _key_plan(self, state: dict, snapshot, now: int) -> list[dict]:
        records = copy.deepcopy(state["keys"])
        for key, record in snapshot.records.items():
            records[key] = {
                **records.get(key, {}),
                "source": "resolver",
                "association": record,
            }
        actions = []
        for key, row in records.items():
            record = row["association"]
            require(
                key != self.native.management_id,
                "management_credential_association_refused",
            )
            try:
                info = self.native.key(key)
            except NativeError as exc:
                if exc.status == 404:
                    actions.append({"action": "retain-missing-key", "logical": key})
                    continue
                raise
            if info.get("blocked") or row.get("retired"):
                actions.append(
                    {
                        "action": "retain-blocked-key"
                        if info.get("blocked")
                        else "block-key",
                        "logical": key,
                    }
                )
                continue
            ceiling = self.desired.key_ceiling(
                record, state["teams"], source=row["source"], now=now
            )
            if row["source"] == "resolver" and key not in snapshot.records:
                ceiling = None
            if ceiling is None:
                actions.append({"action": "block-key", "logical": key})
                continue
            try:
                native_expiry = expiration(info.get("expires"))
            except ControllerError:
                native_expiry = 0
            if native_expiry <= now:
                actions.append({"action": "block-key", "logical": key})
                continue
            ceiling["expires_at"] = min(ceiling["expires_at"], native_expiry)
            current_budget = info.get("max_budget")
            if type(current_budget) in (int, float) and current_budget > 0:
                ceiling["budget"]["usd"] = min(ceiling["budget"]["usd"], current_budget)
            try:
                verify_key(info, record, ceiling, now=now)
                action = "retain-key"
            except ControllerError:
                action = "update-key"
            actions.append(
                {
                    "action": action,
                    "logical": key,
                    "association": record,
                    "ceiling": ceiling,
                    "shorten_expiry": native_expiry > ceiling["expires_at"],
                }
            )
        return actions

    def _apply_infrastructure(self, action: dict) -> None:
        verb, logical, row = (
            action["action"],
            action["logical"],
            copy.deepcopy(action["record"]),
        )
        kind = verb.split("-")[1]
        table = {"credential": "credentials", "alias": "aliases", "team": "teams"}[kind]
        self.ledger.state[table][logical] = row
        self.ledger.save()
        if verb == "create-credential":
            declaration = self.desired.document["service_credentials"][logical]
            secret = self.credential_reader(logical, declaration)
            require(
                isinstance(secret, str) and bool(secret),
                "provider_credential_unavailable",
            )
            self.native.call(
                "POST",
                "/credentials",
                {
                    "credential_name": row["native_id"],
                    "credential_values": {"api_key": secret},
                    "credential_info": row["expected"],
                },
            )
            require(
                self.native.credentials()
                .get(row["native_id"], {})
                .get("credential_info")
                == row["expected"],
                "native_credential_not_applied",
            )
        elif verb in ("create-alias", "update-alias"):
            expected = row.get("pending_expected", row["expected"])
            self.native.call(
                "POST",
                "/model/new" if verb == "create-alias" else "/model/update",
                {
                    "model_name": row["alias"],
                    "litellm_params": expected["litellm_params"],
                    "model_info": {
                        "id": row["native_id"],
                        "mode": "chat",
                        **expected["metadata"],
                    },
                },
            )
            matches = [
                m
                for m in self.native.models()
                if m["model_info"]["id"] == row["native_id"]
            ]
            require(len(matches) == 1, "native_alias_not_applied")
            self._verify_alias(matches[0], {**row, "expected": expected})
            row["expected"] = expected
            row.pop("pending_expected", None)
        elif verb in ("create-team", "update-team"):
            payload = {
                "team_id": row["native_id"],
                "models": self.desired.teams[logical]["models"],
            }
            if verb == "create-team":
                payload["team_alias"] = logical
                payload["metadata"] = {
                    "cc.installation": self.ledger.installation,
                    "cc.domain": row["domain"],
                }
            self.native.call(
                "POST",
                "/team/new" if verb == "create-team" else "/team/update",
                payload,
            )
            actual = self.native.team(row["native_id"])
            require(
                sorted(actual.get("models") or []) == sorted(payload["models"]),
                "native_team_not_applied",
            )
            self._verify_team_routing(actual)
        row["status"] = "owned"
        self.ledger.state[table][logical] = row
        self.ledger.save()

    def _apply_key(self, action: dict, now: int) -> None:
        verb, key = action["action"], action["logical"]
        if verb == "block-key":
            self.native.block(key)
            self.ledger.state["keys"][key]["retired"] = True
            self.ledger.save()
        elif verb == "update-key":
            record, ceiling = action["association"], action["ceiling"]
            patch = {
                "key": key,
                **permissions(record, ceiling),
                "auto_rotate": False,
                "object_permission": EMPTY_OBJECT_PERMISSIONS,
            }
            if action["shorten_expiry"]:
                remaining = ceiling["expires_at"] - int(time.time()) - 1
                if remaining <= 0:
                    self.native.block(key)
                    self.ledger.state["keys"][key]["retired"] = True
                    self.ledger.save()
                    return
                patch["duration"] = f"{remaining}s"
            try:
                self.native.call("POST", "/key/update", patch)
                verify_key(self.native.key(key), record, ceiling, now=now)
            except ControllerError:
                # A failed repair never leaves a known permissive credential classified as legacy.
                self.native.block(key)
                raise

    def run(
        self, *, dry_run: bool = False, rotate: bool = True, now: int | None = None
    ) -> dict:
        now = int(time.time()) if now is None else now
        snapshot = self.associations.read(now)
        with self.ledger.locked(dry_run=dry_run):
            self.ledger.check_snapshot(snapshot)
            self.native.inspect_gateway()
            planned_state = copy.deepcopy(self.ledger.state)
            infrastructure = self._infrastructure_plan(planned_state)
            keys = self._key_plan(planned_state, snapshot, now)
            report = {
                "schema_version": 1,
                "kind": "atrium.litellm-reconciliation",
                "dry_run": dry_run,
                "installation": self.ledger.installation,
                "snapshot_generation": snapshot.document["generation"],
                "actions": [
                    {"action": a["action"], "logical": a["logical"]}
                    for a in infrastructure + keys
                ],
                "adoptions": 0,
                "admission_hook_implemented": False,
            }
            if dry_run:
                report["service_rotation"] = "not-executed"
                return report
            self.ledger.remember(snapshot)
            for action in infrastructure:
                self._apply_infrastructure(action)
            # Re-read all bindings after creation and before touching any existing key.
            self._infrastructure_plan(copy.deepcopy(self.ledger.state))
            for action in keys:
                self._apply_key(action, now)
            self.publish_bindings(now)
            if rotate:
                from .rotation import Rotator

                report["service_rotation"] = Rotator(self).tick(now)
            self.publish_service_associations(now)
            return report
