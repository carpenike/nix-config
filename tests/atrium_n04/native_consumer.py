"""A real long-running fixture consumer, deliberately not the future W03 helper."""

import json
import os
import sys
import time
from pathlib import Path

import httpx

from atrium_litellm.errors import ControllerError
from atrium_litellm.rotation import ServiceKey


def main():
    settings = json.loads(sys.stdin.readline())
    path, ack_path = Path(settings["key_path"]), Path(settings["ack_path"])
    with httpx.Client(
        base_url=settings["endpoint"],
        trust_env=False,
        follow_redirects=False,
        timeout=15,
    ) as client:

        def infer():
            try:
                credential = ServiceKey.read(path, owner_uid=settings["owner_uid"])
            except ControllerError as exc:
                return {
                    "status": "read-failed",
                    "code": exc.code,
                    "provider_fallback": False,
                }
            try:
                response = client.post(
                    "/v1/chat/completions",
                    headers={"Authorization": "Bearer " + credential.token},
                    json={
                        "model": settings["model"],
                        "messages": [
                            {
                                "role": "user",
                                "content": "Synthetic service rotation fixture.",
                            }
                        ],
                        "max_tokens": 4,
                        "stream": False,
                    },
                )
            except httpx.TransportError:
                return {"status": "gateway-failed", "provider_fallback": False}
            result = {
                "status": response.status_code,
                "native_key_id": credential.native_key_id,
                "publication_id": credential.publication_id,
                "provider_fallback": False,
            }
            if response.status_code == 200:
                try:
                    credential.acknowledge(ack_path, group=os.getegid())
                except ControllerError as exc:
                    result["ack_error"] = exc.code
            return result

        for line in sys.stdin:
            command = json.loads(line)
            if command["action"] == "stop":
                break
            results = []
            for _ in range(command.get("count", 1)):
                results.append(infer())
                if command.get("count", 1) > 1:
                    time.sleep(0.08)
            print(json.dumps({"pid": os.getpid(), "requests": results}), flush=True)


if __name__ == "__main__":
    main()
