import asyncio
import json
import logging
import threading

import httpx
from atrium_profiles import ProfileError, PublicKeys
from atrium_profiles.deny import DenyCache

from .models import AdmissionError

logger = logging.getLogger(__name__)


def verified_cache(settings, state, now):
    cache = DenyCache(settings.deny_issuer)
    saved = state["feed"]
    if saved is not None:
        if not isinstance(saved, dict) or set(saved) != {"document", "jwks"}:
            raise AdmissionError("deny_cache_state_invalid", 503)
        cache.receive(saved["document"], PublicKeys(saved["jwks"]), now=now)
    return cache


class Feed:
    def __init__(self, settings, store):
        self.settings, self.store = settings, store
        self.stop = threading.Event()
        self.thread = None

    @staticmethod
    async def _read(client, url):
        async with client.stream("GET", url) as response:
            if response.status_code != 200:
                raise AdmissionError("deny_transport_unavailable", 503)
            data = bytearray()
            async for chunk in response.aiter_bytes():
                data.extend(chunk)
                if len(data) > 65536:
                    raise AdmissionError("deny_transport_oversized", 503)
        return bytes(data)

    async def _fetch(self):
        async with asyncio.timeout(self.settings.fetch_timeout_seconds):
            async with httpx.AsyncClient(
                timeout=self.settings.fetch_timeout_seconds,
                trust_env=False,
                follow_redirects=False,
            ) as client:
                return await asyncio.gather(
                    self._read(client, self.settings.jwks_url),
                    self._read(client, self.settings.deny_url),
                )

    def poll(self, *, force=False):
        with self.store.transaction() as state:
            now = self.store.advance_clock(state)
            if not force and now - state["last_poll"] < self.settings.poll_seconds:
                return
            state["last_poll"] = now
            try:
                cache = verified_cache(self.settings, state, now)
                keys_body, document = asyncio.run(self._fetch())
                jwks = json.loads(keys_body)
                token = document.decode("ascii")
                keys = PublicKeys(jwks)
                now = self.store.advance_clock(state)
                cache.receive(token, keys, now=now)
            except ProfileError as error:
                state["feed_error"] = error.code
            except (
                AdmissionError,
                httpx.HTTPError,
                ValueError,
                UnicodeError,
                TimeoutError,
            ):
                state["feed_error"] = "deny_transport_unavailable"
            else:
                state["feed"] = {"document": token, "jwks": jwks}
                state["feed_error"] = None
            finally:
                self.store.advance_clock(state)

    def start(self):
        if self.thread is not None:
            return

        def loop():
            while not self.stop.is_set():
                try:
                    self.poll()
                except (AdmissionError, ProfileError, OSError, ValueError):
                    logger.error("admission_poll_unavailable")
                self.stop.wait(self.settings.poll_seconds)

        self.thread = threading.Thread(
            target=loop, name="atrium-deny-poll", daemon=True
        )
        self.thread.start()

    def close(self):
        self.stop.set()
        if self.thread is not None:
            self.thread.join(timeout=2 * self.settings.fetch_timeout_seconds + 2)
