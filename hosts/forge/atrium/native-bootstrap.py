"""Explicitly initialize the pinned Home MCP deny store without starting the service."""

import argparse
import json
import os
from pathlib import Path

from homelab_mcp.deny_config import NativeDenySettings
from homelab_mcp.deny_store import DenyStore


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--confirm-new-installation", required=True)
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_bytes())
        if config["installation"] != args.confirm_new_installation:
            raise ValueError("explicit installation required")
        settings = NativeDenySettings.model_validate_json(json.dumps(config["deny"]))
        directory = settings.state_directory
        directory.mkdir(mode=0o700, exist_ok=True)
        if any(directory.iterdir()):
            raise ValueError("existing deny history must not be reset")
        descriptor = os.open(
            directory / "initialization.started",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        with os.fdopen(descriptor, "w") as stream:
            stream.write(config["installation"] + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        store = DenyStore(settings, binding=settings.binding(config["native_issuer"]))
        store.close()
        print(
            json.dumps({"initialized": "native-deny", "native_grants_migrated": False})
        )
    except Exception:
        raise SystemExit("atrium_native_initialization_rejected") from None


if __name__ == "__main__":
    main()
