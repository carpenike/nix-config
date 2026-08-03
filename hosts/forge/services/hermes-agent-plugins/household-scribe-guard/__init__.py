from __future__ import annotations

import hashlib
import hmac
import json
import os
import threading
from dataclasses import dataclass
from datetime import date
from typing import Any, Callable

CONFIRMATION = "noted — it'll get filed at the next review."
_CONTEXT_ADD_SUFFIX = "__finances_context_add"
# SHA-256 of SOPS key hermes-agent/advisor-test-group-id; rotate together.
_ADVISOR_TEST_GROUP_SHA256 = (
    "786b781f203e597ad976c6a18ba93cb19985ee7ba21857600b4f273b1f13e699"
)
_REPLY_PREFIXES = (
    '[Replying to your previous message: "',
    '[Replying to: "',
)
_successful_messages: dict[str, int] = {}
_successful_lock = threading.Lock()


@dataclass(frozen=True)
class ScribeContext:
    message_id: int
    note: str
    author: str
    pulse_reply: bool
    chat_id: str = ""


def _is_context_add(tool_name: str) -> bool:
    return tool_name == "finances_context_add" or tool_name.endswith(
        _CONTEXT_ADD_SUFFIX
    )


def _scribe_writes_blocked(context: ScribeContext) -> bool:
    if not context.chat_id.startswith("group:"):
        return False
    group_id = context.chat_id.removeprefix("group:")
    fingerprint = hashlib.sha256(group_id.encode()).hexdigest()
    return hmac.compare_digest(fingerprint, _ADVISOR_TEST_GROUP_SHA256)


def _split_reply_context(content: str) -> tuple[str, str | None]:
    for prefix in _REPLY_PREFIXES:
        if not content.startswith(prefix):
            continue
        separator = '"]\n\n'
        boundary = content.find(separator, len(prefix))
        if boundary >= 0:
            return content[boundary + len(separator) :], content[len(prefix) : boundary]
    return content, None


def _acceptance_mode() -> bool:
    return os.environ.get("HERMES_SCRIBE_ACCEPTANCE_SIGNAL") == "1"


def _read_scribe_context(session_id: str) -> ScribeContext | None:
    if not session_id:
        return None

    from hermes_state import SessionDB

    database = SessionDB(read_only=True)
    try:
        session = database.get_session(session_id)
        messages = database.get_messages(session_id)
    finally:
        database.close()

    if not session:
        return None
    if session.get("source") != "signal" and not _acceptance_mode():
        return None

    origin = json.loads(session.get("origin_json") or "{}")
    author = str(origin.get("user_name") or "").strip()
    if _acceptance_mode():
        author = os.environ.get("HERMES_SCRIBE_ACCEPTANCE_USER_NAME", author).strip()
    if not author:
        return None

    latest_user = next(
        (message for message in reversed(messages) if message.get("role") == "user"),
        None,
    )
    if not latest_user or not isinstance(latest_user.get("content"), str):
        return None

    note, reply_text = _split_reply_context(latest_user["content"])
    return ScribeContext(
        message_id=int(latest_user["id"]),
        note=note,
        author=author,
        pulse_reply=bool(reply_text and "Couldn't place:" in reply_text),
        chat_id=str(origin.get("chat_id") or "").strip(),
    )


def _rewrite_tool_request(
    *, tool_name: str, args: dict[str, Any], session_id: str = "", **_: Any
) -> dict[str, Any] | None:
    if not _is_context_add(tool_name):
        return None
    context = _read_scribe_context(session_id)
    if context is None:
        return None

    rewritten = dict(args)
    rewritten["note"] = context.note
    rewritten["author"] = context.author
    rewritten["ref_date"] = rewritten.get("ref_date") or date.today().isoformat()
    rewritten["source"] = "pulse_clarify" if context.pulse_reply else "volunteered"
    return {"args": rewritten, "metadata": {"plugin": "household-scribe-guard"}}


def _contains_added(value: Any) -> bool:
    if isinstance(value, dict):
        if value.get("added") is True:
            return True
        return any(_contains_added(item) for item in value.values())
    if isinstance(value, list):
        return any(_contains_added(item) for item in value)
    if isinstance(value, str):
        try:
            return _contains_added(json.loads(value))
        except (json.JSONDecodeError, TypeError):
            return False
    return False


def _guard_tool_execution(
    *,
    tool_name: str,
    args: dict[str, Any],
    next_call: Callable[[dict[str, Any]], Any],
    session_id: str = "",
    **_: Any,
) -> Any:
    if not _is_context_add(tool_name):
        return next_call(args)
    context = _read_scribe_context(session_id)
    if context is None:
        return next_call(args)

    # Advisor Test shares the production persona and tools for realistic Q&A,
    # but test utterances must never enter the family context store.
    if _scribe_writes_blocked(context):
        return json.dumps({"error": "context recording is disabled in Advisor Test"})

    with _successful_lock:
        if _successful_messages.get(session_id) == context.message_id:
            return json.dumps(
                {"error": "purchase context was already recorded this turn"}
            )

    result = next_call(args)
    if _contains_added(result):
        with _successful_lock:
            _successful_messages[session_id] = context.message_id
    return result


def _force_scribe_confirmation(
    *, session_id: str = "", platform: str = "", **_: Any
) -> str | None:
    if platform != "signal" and not _acceptance_mode():
        return None
    context = _read_scribe_context(session_id)
    if context is None:
        return None

    with _successful_lock:
        if _successful_messages.pop(session_id, None) != context.message_id:
            return None
    return CONFIRMATION


def register(context: Any) -> None:
    context.register_middleware("tool_request", _rewrite_tool_request)
    context.register_middleware("tool_execution", _guard_tool_execution)
    context.register_hook("transform_llm_output", _force_scribe_confirmation)
