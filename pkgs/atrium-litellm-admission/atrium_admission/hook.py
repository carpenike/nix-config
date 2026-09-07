import atexit
import os
import threading
from pathlib import Path
from urllib.parse import urlsplit

from atrium_profiles import ProfileError
from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger
from starlette.concurrency import run_in_threadpool

from .cli import load_settings
from .engine import Admission
from .models import AdmissionError


class OwnedAdmission(CustomLogger):
    def __init__(self):
        super().__init__(turn_off_message_logging=True)
        self.engine = None
        self._lock = threading.Lock()

    def _engine(self):
        with self._lock:
            if self.engine is None:
                settings = load_settings(Path(os.environ["ATRIUM_ADMISSION_SETTINGS"]))
                self.engine = Admission(settings)
                atexit.register(self.engine.close)
            return self.engine

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        try:
            transport = data.get("proxy_server_request")
            if (
                not isinstance(transport, dict)
                or transport.get("method") != "POST"
                or not isinstance(transport.get("url"), str)
                or not isinstance(data.get("model"), str)
            ):
                raise AdmissionError("native_request_context_missing")
            path = urlsplit(transport["url"]).path
            engine = await run_in_threadpool(self._engine)
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


admission = OwnedAdmission()
