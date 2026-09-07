import hashlib
import math
import re
import ssl
import time
from datetime import datetime, timezone
from urllib import error, parse, request

from .associations import HASH
from .errors import ControllerError, require
from .files import canonical, decode

CONTROL_ROUTES = {
    "GET": {
        "/health/readiness",
        "/openapi.json",
        "/model/info",
        "/credentials",
        "/team/info",
        "/key/info",
        "/router/settings",
    },
    "POST": {
        "/credentials",
        "/model/new",
        "/model/update",
        "/team/new",
        "/team/update",
        "/key/generate",
        "/key/update",
        "/key/block",
    },
}
SAFE_ROUTER = {
    "num_retries": 0,
    "max_fallbacks": 0,
    "fallbacks": [],
    "context_window_fallbacks": [],
    "content_policy_fallbacks": [],
}
KEY_ROUTER = {
    "num_retries": 0,
    "fallbacks": [],
    "context_window_fallbacks": [],
    "model_group_alias": {},
}
EMPTY_OBJECT_PERMISSIONS = {
    "models": [],
    "mcp_servers": [],
    "mcp_access_groups": [],
    "mcp_tool_permissions": {},
    "mcp_toolsets": [],
    "vector_stores": [],
    "agents": [],
    "agent_access_groups": [],
    "search_tools": [],
    "mcp_tool_search_enabled": False,
}


class NativeError(ControllerError):
    def __init__(self, status: int = 0):
        super().__init__("native_request_failed")
        self.status = status


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def expiration(value: str) -> int:
    require(isinstance(value, str), "native_expiry_missing")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return math.ceil(parsed.timestamp())
    except (ValueError, OverflowError):
        raise ControllerError("invalid_native_expiry") from None


def duration(value: str) -> int:
    match = re.fullmatch(r"([0-9]+)(s|m|h|d)", value or "")
    require(match is not None, "invalid_native_budget_duration")
    return int(match[1]) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[match[2]]


def metadata(record: dict, expires: int) -> dict:
    return {
        "cc.owner": "command-center",
        "cc.template": record["template_id"],
        "cc.principal": record["principal_id"],
        "cc.domain": record["domain"],
        "cc.expires": datetime.fromtimestamp(expires, timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
    }


def permissions(record: dict, ceiling: dict) -> dict:
    return {
        "team_id": record["native_team_id"],
        "models": ceiling["models"],
        "allowed_routes": ceiling["routes"],
        "max_budget": ceiling["budget"]["usd"],
        "budget_duration": f"{ceiling['budget']['duration_seconds']}s",
        "aliases": {},
        "config": {},
        "permissions": {},
        "budget_fallbacks": {},
        "access_group_ids": [],
        "router_settings": KEY_ROUTER,
        "metadata": metadata(record, ceiling["expires_at"]),
    }


def verify_key(info: dict, record: dict, ceiling: dict, *, now: int) -> None:
    require(info.get("team_id") == record["native_team_id"], "native_key_team_mismatch")
    require(
        sorted(info.get("models") or []) == sorted(ceiling["models"]),
        "native_key_models_mismatch",
    )
    require(
        sorted(info.get("allowed_routes") or []) == sorted(ceiling["routes"]),
        "native_key_routes_mismatch",
    )
    require(
        type(info.get("max_budget")) in (int, float)
        and 0 < info["max_budget"] <= ceiling["budget"]["usd"]
        and duration(info.get("budget_duration"))
        == ceiling["budget"]["duration_seconds"],
        "native_key_budget_mismatch",
    )
    expires = expiration(info.get("expires"))
    require(now < expires <= ceiling["expires_at"], "native_key_expiry_mismatch")
    require(not info.get("blocked"), "native_key_blocked")
    for field in ("aliases", "config", "permissions", "budget_fallbacks"):
        require(info.get(field) in ({}, None), "native_key_override")
    require(info.get("access_group_ids") in (None, []), "native_key_extra_grants")
    objects = info.get("object_permission") or {}
    require(
        isinstance(objects, dict)
        and all(
            objects.get(k) is None or objects.get(k) == v
            for k, v in EMPTY_OBJECT_PERMISSIONS.items()
        ),
        "native_key_extra_grants",
    )
    router = info.get("router_settings") or {}
    require(
        isinstance(router, dict)
        and all(router.get(k) == v for k, v in KEY_ROUTER.items())
        and all(
            value is None for key, value in router.items() if key not in KEY_ROUTER
        ),
        "native_key_router_mismatch",
    )
    expected = metadata(record, ceiling["expires_at"])
    require(
        isinstance(info.get("metadata"), dict)
        and all(info["metadata"].get(k) == v for k, v in expected.items()),
        "native_key_metadata_mismatch",
    )


class Native:
    def __init__(
        self,
        endpoint: str,
        management_key: str,
        *,
        timeout: int = 20,
        operations: list | None = None,
    ):
        url = parse.urlsplit(endpoint)
        require(
            url.scheme in ("http", "https")
            and url.hostname
            and not url.username
            and not url.password
            and not url.query
            and not url.fragment
            and url.path in ("", "/"),
            "invalid_native_endpoint",
        )
        require(
            isinstance(management_key, str)
            and management_key.startswith("sk-")
            and "\n" not in management_key
            and "\r" not in management_key,
            "invalid_management_credential",
        )
        self.endpoint = endpoint.rstrip("/")
        self._management_key = management_key
        self.management_id = hashlib.sha256(management_key.encode()).hexdigest()
        self.timeout = timeout
        self.operations = [] if operations is None else operations
        self.opener = request.build_opener(
            request.ProxyHandler({}),
            NoRedirect(),
            request.HTTPSHandler(context=ssl.create_default_context()),
        )

    def call(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        *,
        query: dict | None = None,
    ) -> dict:
        require(path in CONTROL_ROUTES.get(method, set()), "controller_route_forbidden")
        target = self.endpoint + path + ("?" + parse.urlencode(query) if query else "")
        req = request.Request(
            target,
            data=None if body is None else canonical(body),
            method=method,
            headers={
                "Authorization": "Bearer " + self._management_key,
                "Content-Type": "application/json",
            },
        )
        status = 0
        try:
            with self.opener.open(req, timeout=self.timeout) as response:
                status = response.status
                require(status == 200, "unexpected_native_status")
                data = response.read(16 * 1024 * 1024 + 1)
                require(len(data) <= 16 * 1024 * 1024, "native_response_too_large")
                return decode(data)
        except error.HTTPError as exc:
            status = exc.code
            exc.close()
            raise NativeError(status) from None
        except (error.URLError, TimeoutError, ConnectionError, OSError):
            raise NativeError() from None
        finally:
            self.operations.append({"method": method, "path": path, "status": status})

    def inspect_gateway(self) -> None:
        health = self.call("GET", "/health/readiness")
        require(health.get("status") == "healthy", "native_not_ready")
        schema = self.call("GET", "/openapi.json")
        require(
            schema.get("info", {}).get("version") == "1.99.1", "native_version_mismatch"
        )
        routing = self.call("GET", "/router/settings")
        settings = routing.get("current_values", {})
        require(
            all(settings.get(k) == v for k, v in SAFE_ROUTER.items()),
            "unsafe_native_routing",
        )

    def models(self) -> list[dict]:
        result = self.call("GET", "/model/info")
        require(isinstance(result.get("data"), list), "incomplete_native_models")
        for row in result["data"]:
            require(
                isinstance(row, dict)
                and isinstance(row.get("model_name"), str)
                and isinstance(row.get("model_info"), dict)
                and row["model_info"].get("id")
                and isinstance(row.get("litellm_params"), dict),
                "invalid_native_model",
            )
        return result["data"]

    def credentials(self) -> dict[str, dict]:
        result = self.call("GET", "/credentials")
        require(
            result.get("success") is True
            and isinstance(result.get("credentials"), list),
            "incomplete_native_credentials",
        )
        records = {}
        for row in result["credentials"]:
            require(
                isinstance(row, dict)
                and isinstance(row.get("credential_name"), str)
                and row["credential_name"] not in records,
                "invalid_native_credential",
            )
            records[row["credential_name"]] = row
        return records

    def team(self, identity: str) -> dict:
        result = self.call("GET", "/team/info", query={"team_id": identity})
        require(
            result.get("team_id") == identity
            and isinstance(result.get("team_info"), dict)
            and result["team_info"].get("team_id") == identity,
            "native_team_identity_mismatch",
        )
        return result["team_info"]

    def key(self, identity: str) -> dict:
        require(
            HASH.fullmatch(identity) is not None and identity != self.management_id,
            "invalid_native_key_identity",
        )
        result = self.call("GET", "/key/info", query={"key": identity})
        require(
            result.get("key") == identity and isinstance(result.get("info"), dict),
            "native_key_identity_mismatch",
        )
        return result["info"]

    def block(self, identity: str) -> None:
        require(
            HASH.fullmatch(identity) is not None and identity != self.management_id,
            "invalid_native_key_identity",
        )
        self.call("POST", "/key/block", {"key": identity})
        require(self.key(identity).get("blocked") is True, "native_block_not_applied")

    def generate(self, raw_key: str, record: dict, ceiling: dict, *, now: int) -> dict:
        identity = hashlib.sha256(raw_key.encode()).hexdigest()
        require(
            identity == record["native_key_id"] and identity != self.management_id,
            "invalid_native_key_identity",
        )
        lifetime = ceiling["expires_at"] - int(time.time()) - 1
        require(lifetime > 0, "native_key_not_fresh")
        payload = {
            **permissions(record, ceiling),
            "key": raw_key,
            "key_type": "default",
            "duration": f"{lifetime}s",
            "auto_rotate": False,
            "blocked": False,
        }
        result = self.call("POST", "/key/generate", payload)
        require(
            result.get("key") == raw_key and result.get("token_id") == identity,
            "native_issuance_identity_mismatch",
        )
        verify_key(self.key(identity), record, ceiling, now=now)
        return result
