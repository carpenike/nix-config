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
    counts = {"received": 0, "authorized": 0, "models": []}
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
                            self.path == "/_probe/check"
                            and type(data.get("pid")) is int
                        ):
                            if data.get("context_type") != "UserAPIKeyAuth":
                                raise ValueError()
                            blocked = data["key_sha256"] in denied
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
            if self.path != "/v1/chat/completions" or not self.authorized(
                inference_key
            ):
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
                identifier = "n05-fixture-" + str(counts["authorized"])
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

    return Handler


def main():
    credentials = json.loads(sys.stdin.readline())
    ThreadingHTTPServer(
        ("0.0.0.0", 8000), handler(credentials["inference"], credentials["observer"])
    ).serve_forever()


if __name__ == "__main__":
    main()
