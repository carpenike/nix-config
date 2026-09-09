"""Response-only PID observation installed by the native worker startup hook."""

import os

PID_HEADER = b"x-atrium-readback-pid"
POLL_HEADER = b"x-atrium-readback-poll"
REDIS_HEADER = b"x-atrium-readback-redis"


class ObservedResponses:
    def __init__(self, application, observation):
        self.application = application
        self.observation = observation

    async def __call__(self, scope, receive, send):
        async def observed(message):
            if scope["type"] == "http" and message["type"] == "http.response.start":
                pid, interval, redis = self.observation()
                headers = [
                    (key, value)
                    for key, value in message.get("headers", [])
                    if key.lower() not in (PID_HEADER, POLL_HEADER, REDIS_HEADER)
                ]
                message = {
                    **message,
                    "headers": [
                        *headers,
                        (PID_HEADER, str(pid).encode()),
                        (POLL_HEADER, str(interval).encode()),
                        (REDIS_HEADER, b"1" if redis else b"0"),
                    ],
                }
            await send(message)

        await self.application(scope, receive, observed)


async def install():
    from litellm.proxy import proxy_server

    application = proxy_server.app
    if application.middleware_stack is None:
        raise RuntimeError("native_observation_stack_missing")
    if isinstance(application.middleware_stack, ObservedResponses):
        raise RuntimeError("native_observation_already_installed")
    application.middleware_stack = ObservedResponses(
        application.middleware_stack,
        lambda: (
            os.getpid(),
            proxy_server.proxy_config_reload_interval_seconds,
            proxy_server.redis_usage_cache is not None,
        ),
    )
