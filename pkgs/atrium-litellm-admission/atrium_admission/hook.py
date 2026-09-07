import atexit
import logging
import os
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit

from atrium_profiles import ProfileError
from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger
from starlette.concurrency import run_in_threadpool

from .cli import load_settings
from .engine import Admission
from .models import AdmissionError

logger = logging.getLogger(__name__)


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

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        observed = int(time.time())
        try:
            engine = await run_in_threadpool(self._observed_engine, observed)
            transport = data.get("proxy_server_request")
            if (
                not isinstance(transport, dict)
                or transport.get("method") != "POST"
                or not isinstance(transport.get("url"), str)
                or not isinstance(data.get("model"), str)
            ):
                raise AdmissionError("native_request_context_missing")
            path = urlsplit(transport["url"]).path
            await run_in_threadpool(
                engine.admit,
                getattr(user_api_key_dict, "api_key", None),
                getattr(user_api_key_dict, "team_id", None),
                data["model"],
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
