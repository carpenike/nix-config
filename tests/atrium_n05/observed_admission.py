"""Fixture instrumentation forwards every decision to the actual adapter."""

import os

import httpx
from fastapi import HTTPException

from atrium_admission.hook import OwnedAdmission


class ObservedAdmission(OwnedAdmission):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        status = 200
        try:
            return await super().async_pre_call_hook(
                user_api_key_dict, cache, data, call_type
            )
        except HTTPException as error:
            status = error.status_code
            raise
        finally:
            async with httpx.AsyncClient(timeout=5, trust_env=False) as client:
                response = await client.post(
                    os.environ["N05_OBSERVER_URL"] + "/_probe/record",
                    headers={
                        "Authorization": "Bearer " + os.environ["N05_OBSERVER_KEY"]
                    },
                    json={
                        "key_sha256": getattr(user_api_key_dict, "api_key", None),
                        "pid": os.getpid(),
                        "context_type": type(user_api_key_dict).__name__,
                        "status": status,
                        "call_type": call_type,
                    },
                )
                if response.status_code != 200:
                    raise HTTPException(
                        status_code=503, detail="fixture_observer_unavailable"
                    )


admission = ObservedAdmission()
