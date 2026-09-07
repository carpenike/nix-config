import fcntl
import hashlib
import json
import os
import threading
import time
from contextlib import contextmanager

from atrium_profiles.runtime import (
    atomic_private_write,
    private_directory,
    private_open,
)
from atrium_resolver.litellm_inventory import read_document

from .models import AdmissionError

MAX_STATE_BYTES = 64 * 1024 * 1024


def canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode()


def fingerprint(value):
    return hashlib.sha256(canonical(value)).hexdigest()


class State:
    def __init__(self, settings):
        self.directory = private_directory(settings.runtime_directory)
        self.path = self.directory / "admission-state.json"
        self.anchor = self.directory / "initialized"
        self.lock_path = self.directory / "state.lock"
        self._thread_lock = threading.RLock()
        self._last_now = 0
        self.identity = {
            "installation": settings.installation,
            "issuer": settings.issuer,
            "deny_issuer": settings.deny_issuer,
            "producers": [p.model_dump(mode="json") for p in settings.producers],
        }

    @contextmanager
    def _lock(self):
        with self._thread_lock:
            fd = private_open(self.lock_path, os.O_CREAT | os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                yield
            finally:
                os.close(fd)

    def initialize(self):
        with self._lock():
            if self.path.exists() or self.anchor.exists():
                raise AdmissionError("admission_already_initialized", 503)
            fd = private_open(self.anchor, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
            with os.fdopen(fd, "wb") as stream:
                stream.write(b"atrium-owned-admission-v1\n")
                stream.flush()
                os.fsync(stream.fileno())
            atomic_private_write(
                self.path,
                canonical(
                    {
                        "schema_version": 1,
                        "identity": self.identity,
                        "last_now": 0,
                        "producers": {},
                        "history": {},
                        "feed": None,
                        "last_poll": 0,
                        "feed_error": "deny_feed_missing",
                    }
                ),
            )

    @contextmanager
    def transaction(self):
        with self._lock():
            if not self.anchor.exists():
                raise AdmissionError("admission_history_unavailable", 503)
            fd = private_open(self.path, os.O_RDONLY)
            with os.fdopen(fd, "rb") as stream:
                body = stream.read(MAX_STATE_BYTES + 1)
            if len(body) > MAX_STATE_BYTES:
                raise AdmissionError("admission_state_capacity", 503)
            from atrium_resolver.policy_schema import strict_json

            data = strict_json(body)
            if (
                not isinstance(data, dict)
                or set(data)
                != {
                    "schema_version",
                    "identity",
                    "last_now",
                    "producers",
                    "history",
                    "feed",
                    "last_poll",
                    "feed_error",
                }
                or type(data["schema_version"]) is not int
                or data["schema_version"] != 1
                or data["identity"] != self.identity
                or type(data["last_now"]) is not int
                or data["last_now"] < 0
                or type(data["last_poll"]) is not int
                or data["last_poll"] < 0
                or not isinstance(data["history"], dict)
                or not isinstance(data["producers"], dict)
            ):
                raise AdmissionError("admission_history_invalid", 503)
            try:
                yield data
            finally:
                payload = canonical(data)
                if len(payload) > MAX_STATE_BYTES:
                    raise AdmissionError("admission_state_capacity", 503)
                if payload != body:
                    atomic_private_write(self.path, payload)

    def advance_clock(self, state, *, minimum=0):
        with self._thread_lock:
            self._last_now = max(
                self._last_now, minimum, int(time.time()), state["last_now"]
            )
            state["last_now"] = self._last_now
            return self._last_now

    def observe_clock(self, *, minimum=0):
        # Keep the observation in memory even if opening or publishing state fails.
        with self._thread_lock:
            self._last_now = max(self._last_now, minimum, int(time.time()))
        with self.transaction() as state:
            return self.advance_clock(state)


def protected_document(path, uid):
    return read_document(path, publisher_uid=uid)
