import atexit
import logging
import os
import threading
import time
from pathlib import Path

from atrium_profiles import ProfileError
from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger
from starlette.concurrency import run_in_threadpool

from .cli import load_settings
from .engine import Admission
from .models import AdmissionError

logger = logging.getLogger(__name__)

INFERENCE_CALLS = {
    f"{prefix}/{route}": call_type
    for prefix in ("", "/v1")
    for route, call_type in (
        ("chat/completions", "acompletion"),
        ("completions", "atext_completion"),
        ("embeddings", "aembedding"),
        ("responses", "aresponses"),
        ("messages", "anthropic_messages"),
    )
}


class OwnedAdmission(CustomLogger):
    def __init__(self):
        super().__init__(turn_off_message_logging=True)
        self.engine = None
        self._lock = threading.Lock()
        self._last_now = 0

    def _engine(self):
        with self._lock:
            if self.engine is None:
                settings = load_settings(Path(os.environ["ATRIUM_ADMISSION_SETTINGS"]))
                self.engine = Admission(settings)
                atexit.register(self.engine.close)
            return self.engine

    def _observed_engine(self, observed):
        with self._lock:
            self._last_now = max(self._last_now, observed)
        engine = self._engine()
        with self._lock:
            minimum = self._last_now
        engine.store.observe_clock(minimum=minimum)
        return engine

    async def _admit(self, user_api_key_dict, model, path):
        observed = int(time.time())
        try:
            engine = await run_in_threadpool(self._observed_engine, observed)
            return await run_in_threadpool(
                engine.admit,
                getattr(user_api_key_dict, "api_key", None),
                getattr(user_api_key_dict, "team_id", None),
                model,
                path,
            )
        except AdmissionError as error:
            raise HTTPException(status_code=error.status, detail=error.code) from None
        except ProfileError as error:
            raise HTTPException(status_code=403, detail=error.code) from None
        except Exception:
            raise HTTPException(
                status_code=503, detail="admission_unavailable"
            ) from None

    async def async_post_native_auth(self, user_api_key_dict, connection):
        from litellm.proxy.common_utils.http_parsing_utils import _read_request_body

        route = getattr(user_api_key_dict, "request_route", None)
        model, path = None, None
        if (
            connection.scope["type"] == "http"
            and connection.scope.get("method") == "POST"
            and isinstance(route, str)
            and route in INFERENCE_CALLS
        ):
            data = await _read_request_body(connection)
            model = data.get("model") if isinstance(data, dict) else None
            path = route
        return await self._admit(user_api_key_dict, model, path)

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        # Native auth stamps this from ASGI scope; raw passthrough body fields
        # named proxy_server_request are not authenticated transport context.
        route = getattr(user_api_key_dict, "request_route", None)
        path = (
            route
            if isinstance(route, str)
            and route in INFERENCE_CALLS
            and INFERENCE_CALLS[route] == call_type
            else None
        )
        await self._admit(
            user_api_key_dict,
            data.get("model") if isinstance(data, dict) else None,
            path,
        )
        return data

    async def async_post_call_failure_hook(
        self, request_data, original_exception, user_api_key_dict, traceback_str=None
    ):
        # Native 1.99.1 awaits this even when authentication rejects before admission.
        observed = int(time.time())
        try:
            await run_in_threadpool(self._observed_engine, observed)
        except (AdmissionError, ProfileError, OSError, KeyError, ValueError):
            logger.error("admission_failure_clock_unavailable")
        return None


admission = OwnedAdmission()
