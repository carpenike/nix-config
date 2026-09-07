"""Fixture-only placement instrumentation, not the production Atrium adapter."""

import os
import re

import httpx
from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger


class PlacementProbe(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        identity = getattr(user_api_key_dict, "api_key", None)
        if (
            not isinstance(identity, str)
            or re.fullmatch(r"[0-9a-f]{64}", identity) is None
        ):
            raise HTTPException(
                status_code=503, detail="n05_probe_native_identity_missing"
            )
        metadata = getattr(user_api_key_dict, "metadata", None) or {}
        event = {
            "pid": os.getpid(),
            "key_sha256": identity,
            "context_type": type(user_api_key_dict).__name__,
            "native_principal": metadata.get("cc.principal"),
            "native_team": getattr(user_api_key_dict, "team_id", None),
            "call_type": call_type,
        }
        async with httpx.AsyncClient(
            timeout=5, trust_env=False, follow_redirects=False
        ) as client:
            response = await client.post(
                os.environ["N05_OBSERVER_URL"] + "/_probe/check",
                headers={"Authorization": "Bearer " + os.environ["N05_OBSERVER_KEY"]},
                json=event,
            )
        if response.status_code != 200 or type(response.json().get("deny")) is not bool:
            raise HTTPException(
                status_code=503, detail="n05_probe_observer_unavailable"
            )
        if response.json()["deny"]:
            raise HTTPException(status_code=403, detail="n05_fixture_denied")
        return data


probe = PlacementProbe()
