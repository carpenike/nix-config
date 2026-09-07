import argparse
import json
import os
from pathlib import Path

from atrium_resolver.litellm_inventory import read_document

from .models import Settings
from .state import State


def load_settings(path):
    if path.resolve().is_relative_to("/nix/store"):
        with path.open("rb") as stream:
            data = stream.read(65537)
        if len(data) > 65536:
            raise ValueError("Admission settings exceed size bound")
        return Settings.model_validate_json(data)
    return Settings.model_validate_json(
        json.dumps(read_document(path, publisher_uid=os.geteuid()))
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--settings", type=Path, required=True)
    parser.add_argument("operation", choices=("initialize", "status"))
    args = parser.parse_args()
    try:
        settings = load_settings(args.settings)
        store = State(settings)
        if args.operation == "initialize":
            store.initialize()
            result = {"initialized": True}
        else:
            with store.transaction() as data:
                result = {
                    "known_owned": len(data["history"]),
                    "producers": sorted(data["producers"]),
                    "feed_present": data["feed"] is not None,
                    "feed_error": data["feed_error"],
                }
    except Exception:
        print(json.dumps({"error": "admission_state_unavailable"}))
        raise SystemExit(2) from None
    print(json.dumps(result))
