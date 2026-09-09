"""Response-only PID observation installed by the native worker startup hook."""

import logging
import os
import re
import time

PID_HEADER = b"x-atrium-readback-pid"
POLL_HEADER = b"x-atrium-readback-poll"
REDIS_HEADER = b"x-atrium-readback-redis"
REFRESH_HEADERS = {
    "runs": b"x-atrium-readback-refresh-runs",
    "failed": b"x-atrium-readback-refresh-failed",
    "error_class": b"x-atrium-readback-refresh-error",
    "next_ms": b"x-atrium-readback-refresh-next-ms",
    "store_models": b"x-atrium-readback-store-models",
    "ready": b"x-atrium-readback-refresh-ready",
}


class RefreshObservation(logging.Handler):
    def __init__(self, event_mask=0):
        super().__init__()
        self.runs = 0
        self.failed = 0
        self.error_class = "none"
        self.event_mask = event_mask
        self.scheduler = None

    def snapshot(self, scheduler, store_models):
        if scheduler is not None and scheduler is not self.scheduler:
            scheduler.add_listener(self.event, self.event_mask)
            self.scheduler = scheduler
        job = (
            scheduler.get_job("get_credentials_job") if scheduler is not None else None
        )
        next_run = getattr(job, "next_run_time", None)
        return {
            "runs": self.runs,
            "failed": self.failed,
            "error_class": self.error_class,
            "next_ms": round((next_run.timestamp() - time.time()) * 1000)
            if next_run is not None
            else -1,
            "store_models": int(store_models is True),
            "ready": int(next_run is not None),
        }

    def event(self, event):
        if event.job_id == "get_credentials_job":
            self.runs += 1
            if getattr(event, "exception", None) is not None or event.retval == []:
                self.failed += 1

    def emit(self, record):
        if (
            isinstance(record.msg, str)
            and record.msg.startswith(
                "litellm.proxy_server.py::get_credentials() - Error getting credentials from DB"
            )
            and record.exc_info
        ):
            name = record.exc_info[0].__name__
            self.error_class = (
                name if re.fullmatch("[A-Za-z_][A-Za-z0-9_]{0,63}", name) else "other"
            )


class ObservedResponses:
    def __init__(self, application, observation, refresh=None):
        self.application = application
        self.observation = observation
        self.refresh = refresh

    async def __call__(self, scope, receive, send):
        async def observed(message):
            if scope["type"] == "http" and message["type"] == "http.response.start":
                pid, interval, redis = self.observation()
                headers = [
                    (key, value)
                    for key, value in message.get("headers", [])
                    if key.lower()
                    not in (
                        PID_HEADER,
                        POLL_HEADER,
                        REDIS_HEADER,
                        *REFRESH_HEADERS.values(),
                    )
                ]
                extra = []
                if self.refresh is not None:
                    extra = [
                        (REFRESH_HEADERS[name], str(value).encode())
                        for name, value in self.refresh().items()
                    ]
                message = {
                    **message,
                    "headers": [
                        *headers,
                        (PID_HEADER, str(pid).encode()),
                        (POLL_HEADER, str(interval).encode()),
                        (REDIS_HEADER, b"1" if redis else b"0"),
                        *extra,
                    ],
                }
            await send(message)

        await self.application(scope, receive, observed)


async def install():
    from apscheduler.events import EVENT_JOB_ERROR, EVENT_JOB_EXECUTED
    from litellm.proxy import proxy_server

    application = proxy_server.app
    if application.middleware_stack is None:
        raise RuntimeError("native_observation_stack_missing")
    if isinstance(application.middleware_stack, ObservedResponses):
        raise RuntimeError("native_observation_already_installed")
    refresh = RefreshObservation(EVENT_JOB_EXECUTED | EVENT_JOB_ERROR)
    proxy_server.verbose_proxy_logger.addHandler(refresh)

    def refresh_state():
        return refresh.snapshot(
            getattr(proxy_server, "scheduler", None), proxy_server.store_model_in_db
        )

    application.middleware_stack = ObservedResponses(
        application.middleware_stack,
        lambda: (
            os.getpid(),
            proxy_server.proxy_config_reload_interval_seconds,
            proxy_server.redis_usage_cache is not None,
        ),
        refresh_state,
    )
