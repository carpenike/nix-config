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
    counts = {"received": 0, "authorized": 0, "models": [], "protocols": []}
    events, denied = [], set()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def authorized(self, key):
            return secrets.compare_digest(
                self.headers.get("Authorization", ""), "Bearer " + key
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
            if not self.authorized(observer_key):
                self.reply(401, {"error": "unauthorized"})
                return
            with lock:
                if self.path == "/_fixture/counts":
                    self.reply(200, counts)
                elif self.path == "/_probe/state":
                    self.reply(200, {"provider": counts, "events": events})
                else:
                    self.reply(404, {"error": "unknown_probe_route"})

        def do_POST(self):
            if self.path.startswith("/_probe/"):
                if not self.authorized(observer_key):
                    self.reply(401, {"error": "unauthorized"})
                    return
                try:
                    data = self.body()
                    if not isinstance(data, dict) or not re.fullmatch(
                        r"[0-9a-f]{64}", data["key_sha256"]
                    ):
                        raise ValueError()
                    with lock:
                        if (
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
            if self.path not in (
                "/v1/chat/completions",
                "/v1/completions",
                "/v1/embeddings",
                "/v1/responses",
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

        def sse(self, events, *, done):
            body = b"".join(
                ("data: " + json.dumps(event) + "\n\n").encode() for event in events
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
