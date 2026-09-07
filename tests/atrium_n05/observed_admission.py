"""Fixture instrumentation forwards every decision to the actual adapter."""

import importlib
import json
import os
import re
import time
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

import httpx
from fastapi import HTTPException

from atrium_admission.hook import OwnedAdmission

REVIEW_CLOCK = os.environ.get("N05_REVIEW_CLOCK") == "1"

if REVIEW_CLOCK:
    clock_path = Path("/run/atrium-n05/review-clock.json")

    def fixture_now():
        if not clock_path.exists():
            return time.time()
        value = json.loads(clock_path.read_text())["now"]
        return time.time() if value is None else value

    class ClockType(type):
        def __instancecheck__(cls, value):
            return isinstance(value, datetime)

    class FixtureDatetime(datetime, metaclass=ClockType):
        @classmethod
        def now(cls, tz=None):
            return datetime.fromtimestamp(fixture_now(), tz)

    # Only clock inputs change; native key lookup, expiry checks and admission stay real.
    importlib.import_module(
        "litellm.proxy.auth.user_api_key_auth"
    ).datetime = FixtureDatetime
    for name in ("atrium_admission.state", "atrium_admission.hook"):
        importlib.import_module(name).time = SimpleNamespace(time=fixture_now)


class ObservedAdmission(OwnedAdmission):
    def _engine(self):
        engine = super()._engine()
        if REVIEW_CLOCK:
            engine.feed.close()
        return engine

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

    async def async_post_call_failure_hook(
        self, request_data, original_exception, user_api_key_dict, traceback_str=None
    ):
        result = await super().async_post_call_failure_hook(
            request_data, original_exception, user_api_key_dict, traceback_str
        )
        key_hash = getattr(user_api_key_dict, "api_key", None)
        if (
            self.engine is None
            or not isinstance(key_hash, str)
            or not re.fullmatch("[0-9a-f]{64}", key_hash)
        ):
            return result
        with self.engine.store.transaction() as state:
            now = state["last_now"]
        async with httpx.AsyncClient(timeout=5, trust_env=False) as client:
            response = await client.post(
                os.environ["N05_OBSERVER_URL"] + "/_probe/clock",
                headers={"Authorization": "Bearer " + os.environ["N05_OBSERVER_KEY"]},
                json={"key_sha256": key_hash, "pid": os.getpid(), "last_now": now},
            )
            if response.status_code != 200:
                raise HTTPException(
                    status_code=503, detail="fixture_observer_unavailable"
                )
        return result


admission = ObservedAdmission()
