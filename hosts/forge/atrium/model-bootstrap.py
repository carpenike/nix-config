"""Local model initialization and retained N04 publication using actual producers."""

import argparse
import json
import os
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "producer", choices=("resolver", "controller", "controller-publication")
    )
    parser.add_argument("--config", type=Path, required=True)
    confirmation = parser.add_mutually_exclusive_group(required=True)
    confirmation.add_argument("--confirm-new-installation")
    confirmation.add_argument("--confirm-existing-installation")
    args = parser.parse_args()
    publication = args.producer == "controller-publication"
    try:
        if publication:
            if args.confirm_existing_installation is None:
                raise ValueError("explicit existing model installation required")
            installation = args.confirm_existing_installation
        else:
            if args.confirm_new_installation is None:
                raise ValueError("explicit new model installation required")
            installation = args.confirm_new_installation
        if args.producer == "resolver":
            from atrium_resolver.config import load_settings
            from atrium_resolver.litellm_broker import LiteLLMBroker
            from atrium_resolver.policy import PolicyEngine
            from atrium_resolver.state import State

            settings = load_settings(args.config)
            if (
                settings.litellm is None
                or settings.litellm.installation != installation
            ):
                raise ValueError("explicit model installation required")
            directory = settings.litellm.runtime_directory
            directory.mkdir(mode=0o700, exist_ok=True)
            if any(directory.iterdir()):
                raise ValueError("existing model history must not be reset")
            marker = directory / "initialization.started"
            descriptor = os.open(
                marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
            )
            # Leave a refusal marker even if initialization fails partway through.
            with os.fdopen(descriptor, "w") as stream:
                stream.write(installation + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            state = State(settings.state_directory)
            try:
                engine = PolicyEngine(settings, state)
                engine.snapshot()
                broker = LiteLLMBroker(engine, settings.litellm)
                broker.close()
            finally:
                state.close()
            descriptor = os.open(
                directory / "initialized",
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
            )
            with os.fdopen(descriptor, "w") as stream:
                stream.write(installation + "\n")
                stream.flush()
                os.fsync(stream.fileno())
        else:
            from atrium_litellm.associations import ProtectedSnapshotSource
            from atrium_litellm.controller import Controller
            from atrium_litellm.desired import Desired
            from atrium_litellm.files import read_bytes
            from atrium_litellm.ledger import Ledger
            from atrium_litellm.native import Native

            config = json.loads(args.config.read_bytes())
            if config["installation"] != installation:
                raise ValueError("explicit controller installation required")
            desired = Desired.read(Path(config["desired_state"]))
            if desired.document["environment"] != config["environment"]:
                raise ValueError("controller environment mismatch")
            desired.check_transports(
                config["endpoint"], config["issuer"], config["backend_transports"]
            )
            source = ProtectedSnapshotSource(
                Path(config["association_snapshot"]),
                config["installation"],
                config["issuer"],
                config["association_publisher_uid"],
            )
            # Retained service publication must not depend on the other producer
            # or on management requests that require this publication to be fresh.
            if not publication:
                source.read(int(time.time()))
            ledger = Ledger(
                Path(config["ownership_directory"]),
                config["installation"],
                config["issuer"],
            )
            control = (
                read_bytes(
                    Path(config["management_key_file"]), secret=True, limit=16384
                )
                .decode()
                .strip()
            )
            controller = Controller(
                desired,
                ledger,
                Native(config["endpoint"], control),
                source,
                config["backend_transports"],
                service_delivery=config["service_delivery"],
                service_association_snapshot=Path(
                    config["service_association_snapshot"]
                ),
                bindings_snapshot=Path(config["bindings_snapshot"]),
                publication_reader_gid=config["publication_reader_gid"],
            )
            if not publication:
                ledger.initialize()
            with ledger.locked():
                ledger.save()
                controller.publish_service_associations(int(time.time()))
            # Native bindings are published only after real reconciliation/readback,
            # never invented during this zero-adoption local initialization.
        result = (
            {"published": "controller"}
            if publication
            else {"initialized": args.producer}
        )
        print(json.dumps({**result, "native_writes": False}))
    except Exception:
        code = (
            "atrium_model_publication_rejected"
            if publication
            else "atrium_model_initialization_rejected"
        )
        raise SystemExit(code) from None


if __name__ == "__main__":
    main()
