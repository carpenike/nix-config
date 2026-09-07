"""Non-actuating streaming provider and authenticated placement observer."""

import json
import re
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MARKER = "fixture-ok-n05"


def handler(inference_key, observer_key):
    lock = threading.Lock()
    counts = {
        "received": 0,
        "authorized": 0,
        "models": [],
        "protocols": [],
        "requests": [],
    }
    events, denied = [], set()
    clocks = []
    auth_events, installations = [], []
    bootstrap_errors = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def authorized(self, key):
            return secrets.compare_digest(
                self.headers.get("Authorization", ""), "Bearer " + key
            )

        def anthropic_authorized(self):
            return secrets.compare_digest(
                self.headers.get("x-api-key", ""), inference_key
            )

        def reply(self, status, document):
            body = json.dumps(document).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def body(self):
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 65536:
                raise ValueError()
            return json.loads(self.rfile.read(length))

        def do_GET(self):
            if self.path == "/v1/models":
                with lock:
                    counts["received"] += 1
                    counts["requests"].append({"method": "GET", "path": self.path})
                if not self.anthropic_authorized():
                    self.reply(401, {"error": "unauthorized"})
                    return
                with lock:
                    counts["authorized"] += 1
                    counts["protocols"].append(
                        {"path": self.path, "stream": False, "legacy_passthrough": True}
                    )
                self.reply(
                    200,
                    {
                        "data": [
                            {
                                "id": "fixture-legacy",
                                "type": "model",
                                "display_name": "Legacy fixture",
                                "created_at": "2026-01-01T00:00:00Z",
                            }
                        ],
                        "has_more": False,
                    },
                )
                return
            if not self.authorized(observer_key):
                self.reply(401, {"error": "unauthorized"})
                return
            with lock:
                if self.path == "/_fixture/counts":
                    self.reply(200, counts)
                elif self.path == "/_probe/state":
                    self.reply(
                        200,
                        {
                            "provider": counts,
                            "events": events,
                            "auth_events": auth_events,
                            "installations": installations,
                            "bootstrap_errors": bootstrap_errors,
                        },
                    )
                elif self.path == "/_probe/clocks":
                    self.reply(200, clocks)
                else:
                    self.reply(404, {"error": "unknown_probe_route"})

        def do_POST(self):
            if self.path.startswith("/_probe/"):
                if not self.authorized(observer_key):
                    self.reply(401, {"error": "unauthorized"})
                    return
                try:
                    data = self.body()
                    if self.path == "/_probe/bootstrap_error":
                        if (
                            set(data) != {"pid", "exception", "file", "line"}
                            or type(data["pid"]) is not int
                            or type(data["line"]) is not int
                            or not isinstance(data["file"], str)
                            or not isinstance(data["exception"], str)
                        ):
                            raise ValueError()
                        with lock:
                            bootstrap_errors.append(data)
                        self.reply(200, {"recorded": True})
                        return
                    if self.path == "/_probe/install":
                        if (
                            set(data) != {"pid", "dependency_paths"}
                            or type(data["pid"]) is not int
                            or set(data["dependency_paths"]) != {"request", "websocket"}
                            or not all(
                                isinstance(paths, list)
                                and all(
                                    isinstance(path, str) and path.startswith("/")
                                    for path in paths
                                )
                                for paths in data["dependency_paths"].values()
                            )
                        ):
                            raise ValueError()
                        with lock:
                            installations.append(data)
                        self.reply(200, {"recorded": True})
                        return
                    if not isinstance(data, dict) or not re.fullmatch(
                        r"[0-9a-f]{64}", data["key_sha256"]
                    ):
                        raise ValueError()
                    with lock:
                        if self.path == "/_probe/clock":
                            if set(data) != {"key_sha256", "pid", "last_now"} or any(
                                type(data[name]) is not int or data[name] < 0
                                for name in ("pid", "last_now")
                            ):
                                raise ValueError()
                            clocks.append(data)
                            self.reply(200, {"recorded": True})
                        elif self.path == "/_probe/auth":
                            if (
                                set(data)
                                != {
                                    "key_sha256",
                                    "pid",
                                    "context_type",
                                    "status",
                                    "native_request_route",
                                    "transport",
                                }
                                or type(data["pid"]) is not int
                                or data["context_type"] != "UserAPIKeyAuth"
                                or type(data["status"]) is not int
                                or data["transport"] not in ("http", "websocket")
                                or not isinstance(data["native_request_route"], str)
                            ):
                                raise ValueError()
                            auth_events.append(data)
                            self.reply(200, {"recorded": True})
                        elif (
                            self.path == "/_probe/deny"
                            and type(data.get("deny")) is bool
                        ):
                            (denied.add if data["deny"] else denied.discard)(
                                data["key_sha256"]
                            )
                            self.reply(200, {"applied": True})
                        elif (
                            self.path in ("/_probe/check", "/_probe/record")
                            and type(data.get("pid")) is int
                        ):
                            if data.get("context_type") != "UserAPIKeyAuth":
                                raise ValueError()
                            blocked = (
                                data["key_sha256"] in denied
                                if self.path == "/_probe/check"
                                else data["status"] != 200
                            )
                            events.append(
                                {**data, "denied": blocked, "sequence": len(events)}
                            )
                            self.reply(200, {"deny": blocked})
                        else:
                            raise ValueError()
                except (ValueError, TypeError, KeyError):
                    self.reply(400, {"error": "invalid_probe_request"})
                return
            with lock:
                counts["received"] += 1
                counts["requests"].append({"method": "POST", "path": self.path})
            if self.path == "/v1/messages":
                if not self.anthropic_authorized():
                    self.reply(401, {"error": "unauthorized"})
                    return
                try:
                    data = self.body()
                    model = data["model"]
                    if (
                        model not in ("cc.family.text", "cc.personal.text")
                        or type(data.get("stream", False)) is not bool
                    ):
                        raise ValueError()
                except (ValueError, TypeError, KeyError):
                    self.reply(400, {"error": "unsupported_fixture_request"})
                    return
                with lock:
                    counts["authorized"] += 1
                    counts["models"].append(model)
                    counts["protocols"].append(
                        {
                            "path": self.path,
                            "stream": data.get("stream", False),
                            "legacy_passthrough": True,
                        }
                    )
                    identifier = "msg_n05_legacy_" + str(counts["authorized"])
                completed = {
                    "id": identifier,
                    "type": "message",
                    "role": "assistant",
                    "model": model,
                    "content": [{"type": "text", "text": MARKER}],
                    "stop_reason": "end_turn",
                    "stop_sequence": None,
                    "usage": {"input_tokens": 1, "output_tokens": 1},
                }
                if not data.get("stream"):
                    self.reply(200, completed)
                else:
                    self.sse(
                        [
                            {
                                "type": "message_start",
                                "message": completed
                                | {
                                    "content": [],
                                    "stop_reason": None,
                                    "usage": {"input_tokens": 1, "output_tokens": 0},
                                },
                            },
                            {
                                "type": "content_block_start",
                                "index": 0,
                                "content_block": {"type": "text", "text": ""},
                            },
                            {
                                "type": "content_block_delta",
                                "index": 0,
                                "delta": {"type": "text_delta", "text": MARKER},
                            },
                            {"type": "content_block_stop", "index": 0},
                            {
                                "type": "message_delta",
                                "delta": {
                                    "stop_reason": "end_turn",
                                    "stop_sequence": None,
                                },
                                "usage": {"output_tokens": 1},
                            },
                            {"type": "message_stop"},
                        ],
                        done=False,
                        named=True,
                    )
                return
            if self.path not in (
                "/v1/chat/completions",
                "/v1/completions",
                "/v1/embeddings",
                "/v1/responses",
                "/v1/responses/input_tokens",
            ) or not self.authorized(inference_key):
                self.reply(401, {"error": "unauthorized"})
                return
            try:
                data = self.body()
                model = data["model"]
                if (
                    model not in ("fixture-family", "fixture-personal")
                    or type(data.get("stream", False)) is not bool
                ):
                    raise ValueError()
            except (ValueError, TypeError, KeyError):
                self.reply(400, {"error": "unsupported_fixture_request"})
                return
            with lock:
                counts["authorized"] += 1
                counts["models"].append(model)
                counts["protocols"].append(
                    {
                        "path": self.path,
                        "stream": data.get("stream", False),
                        "include_usage": isinstance(data.get("stream_options"), dict)
                        and data["stream_options"].get("include_usage") is True,
                    }
                )
                identifier = "n05-fixture-" + str(counts["authorized"])
            if self.path == "/v1/responses/input_tokens":
                self.reply(200, {"object": "response.input_tokens", "input_tokens": 7})
                return
            if self.path == "/v1/embeddings":
                values = data.get("input", "")
                number = len(values) if isinstance(values, list) else 1
                self.reply(
                    200,
                    {
                        "object": "list",
                        "model": model,
                        "data": [
                            {
                                "object": "embedding",
                                "index": index,
                                "embedding": [0.1, 0.2, 0.3],
                            }
                            for index in range(number)
                        ],
                        "usage": {"prompt_tokens": 1, "total_tokens": 1},
                    },
                )
                return
            if self.path == "/v1/completions":
                completed = {
                    "id": identifier,
                    "object": "text_completion",
                    "created": 1,
                    "model": model,
                    "choices": [
                        {
                            "index": 0,
                            "text": MARKER,
                            "finish_reason": "stop",
                            "logprobs": None,
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 1,
                        "completion_tokens": 1,
                        "total_tokens": 2,
                    },
                }
                if not data.get("stream"):
                    self.reply(200, completed)
                else:
                    streamed = {
                        key: value for key, value in completed.items() if key != "usage"
                    }
                    chunks = [
                        streamed
                        | {
                            "choices": [
                                {
                                    "index": 0,
                                    "text": MARKER,
                                    "finish_reason": None,
                                    "logprobs": None,
                                }
                            ]
                        },
                        streamed
                        | {
                            "choices": [
                                {
                                    "index": 0,
                                    "text": "",
                                    "finish_reason": "stop",
                                    "logprobs": None,
                                }
                            ]
                        },
                    ]
                    if (
                        isinstance(data.get("stream_options"), dict)
                        and data["stream_options"].get("include_usage") is True
                    ):
                        chunks.append(
                            streamed | {"choices": [], "usage": completed["usage"]}
                        )
                    self.sse(
                        chunks,
                        done=True,
                    )
                return
            if self.path == "/v1/responses":
                message = {
                    "id": "msg_" + identifier,
                    "type": "message",
                    "role": "assistant",
                    "status": "completed",
                    "content": [
                        {"type": "output_text", "text": MARKER, "annotations": []}
                    ],
                }
                completed = {
                    "id": "resp_" + identifier,
                    "object": "response",
                    "created_at": 1,
                    "status": "completed",
                    "model": model,
                    "output": [message],
                    "parallel_tool_calls": False,
                    "tools": [],
                    "tool_choice": "auto",
                    "error": None,
                    "incomplete_details": None,
                    "instructions": None,
                    "metadata": {},
                    "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
                }
                if not data.get("stream"):
                    self.reply(200, completed)
                else:
                    response_events = [
                        {
                            "type": "response.created",
                            "response": completed
                            | {"status": "in_progress", "output": []},
                        },
                        {
                            "type": "response.output_item.added",
                            "output_index": 0,
                            "item": message | {"status": "in_progress", "content": []},
                        },
                        {
                            "type": "response.content_part.added",
                            "item_id": message["id"],
                            "output_index": 0,
                            "content_index": 0,
                            "part": {
                                "type": "output_text",
                                "text": "",
                                "annotations": [],
                            },
                        },
                        {
                            "type": "response.output_text.delta",
                            "item_id": message["id"],
                            "output_index": 0,
                            "content_index": 0,
                            "delta": MARKER,
                        },
                        {
                            "type": "response.output_text.done",
                            "item_id": message["id"],
                            "output_index": 0,
                            "content_index": 0,
                            "text": MARKER,
                        },
                        {
                            "type": "response.output_item.done",
                            "output_index": 0,
                            "item": message,
                        },
                        {"type": "response.completed", "response": completed},
                    ]
                    self.sse(
                        [
                            event | {"sequence_number": index}
                            for index, event in enumerate(response_events)
                        ],
                        done=False,
                    )
                return
            if not data.get("stream"):
                self.reply(
                    200,
                    {
                        "id": identifier,
                        "object": "chat.completion",
                        "created": 1,
                        "model": model,
                        "choices": [
                            {
                                "index": 0,
                                "message": {"role": "assistant", "content": MARKER},
                                "finish_reason": "stop",
                            }
                        ],
                        "usage": {
                            "prompt_tokens": 1,
                            "completion_tokens": 1,
                            "total_tokens": 2,
                        },
                    },
                )
                return
            chunks = [
                {
                    "index": 0,
                    "delta": {"role": "assistant", "content": "fixture-"},
                    "finish_reason": None,
                },
                {"index": 0, "delta": {"content": "ok-n05"}, "finish_reason": None},
                {"index": 0, "delta": {}, "finish_reason": "stop"},
            ]
            payload = [
                (
                    "data: "
                    + json.dumps(
                        {
                            "id": identifier,
                            "object": "chat.completion.chunk",
                            "created": 1,
                            "model": model,
                            "choices": [chunk],
                        }
                    )
                    + "\n\n"
                ).encode()
                for chunk in chunks
            ]
            payload.append(
                (
                    "data: "
                    + json.dumps(
                        {
                            "id": identifier,
                            "object": "chat.completion.chunk",
                            "created": 1,
                            "model": model,
                            "choices": [],
                            "usage": {
                                "prompt_tokens": 1,
                                "completion_tokens": 1,
                                "total_tokens": 2,
                            },
                        }
                    )
                    + "\n\n"
                ).encode()
            )
            payload.append(b"data: [DONE]\n\n")
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(sum(map(len, payload))))
            self.end_headers()
            for chunk in payload:
                self.wfile.write(chunk)
                self.wfile.flush()

        def sse(self, events, *, done, named=False):
            body = b"".join(
                (
                    ("event: " + event["type"] + "\n" if named else "")
                    + "data: "
                    + json.dumps(event)
                    + "\n\n"
                ).encode()
                for event in events
            )
            if done:
                body += b"data: [DONE]\n\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()

    return Handler


def main():
    credentials = json.loads(sys.stdin.readline())
    ThreadingHTTPServer(
        ("0.0.0.0", 8000), handler(credentials["inference"], credentials["observer"])
    ).serve_forever()


if __name__ == "__main__":
    main()
