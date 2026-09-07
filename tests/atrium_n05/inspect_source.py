"""Read actual pinned image source in one small network-disabled owned container."""

import argparse
import hashlib
import json
import secrets
from pathlib import Path

from supervisor import ROOT, inventory, load_harness, ready, write_json

SOURCE_PROBE = """
import importlib.metadata, importlib.util, json, pathlib
root = pathlib.Path(importlib.util.find_spec("litellm").origin).parent
names = (
 "proxy/proxy_server.py", "proxy/common_request_processing.py", "proxy/utils.py",
 "proxy/auth/user_api_key_auth.py", "integrations/custom_logger.py",
 "proxy/types_utils/utils.py", "proxy/proxy_cli.py",
 "caching/caching.py", "caching/in_memory_cache.py", "utils.py",
 "types/proxy/_types.py", "router.py",
)
print(json.dumps({
 "version": importlib.metadata.version("litellm"),
 "files": {name: (root/name).read_text() for name in names if (root/name).is_file()}
}))
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--harness", type=Path, required=True)
    args = parser.parse_args()
    native, hashes = load_harness(args.harness)
    from harness.common import PINS, require
    from harness.containers import Resources

    result = {"shared_harness_sha256": hashes}
    resources = Resources("n05-source-" + secrets.token_hex(8), result)
    before = ready(resources)
    try:
        host = json.loads(resources.command(["info", "--format", "json"]))
        arch = host["host"]["arch"]
        image = resources.image(PINS["litellm"]["image"], "linux/" + arch)
        require(
            "ghcr.io/berriai/litellm@" + PINS["litellm"]["platform_manifests"][arch]
            in image["repo_digests"],
            "pinned_platform_mismatch",
        )
        identifier = resources.create(
            "source",
            image["image_id"],
            "python",
            ["-B", "-c", SOURCE_PROBE],
            memory="512m",
            network=False,
        )
        payload = json.loads(
            resources.command(["start", "--attach", identifier], timeout=60)
        )
        require(payload["version"] == "1.99.1", "pinned_version_mismatch")
        files = {}
        for name, text in payload["files"].items():
            path = ROOT / ".artifacts/n05-pinned-source" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            files[name] = hashlib.sha256(text.encode()).hexdigest()
        result.update(version=payload["version"], image=image, source_sha256=files)
    finally:
        resources.cleanup()
        after = inventory(resources)
        result["foreign_resources_unchanged"] = all(
            after.get(key) == row for key, row in before.items()
        )
        write_json(ROOT / ".artifacts/n05-source-inspection.json", result)
    require(result["foreign_resources_unchanged"], "foreign_resource_changed")
    print(
        json.dumps(
            {
                "status": "passed",
                "version": result["version"],
                "source_files": len(result["source_sha256"]),
                "cleanup": result["cleanup"]["status"],
            }
        )
    )


if __name__ == "__main__":
    main()
