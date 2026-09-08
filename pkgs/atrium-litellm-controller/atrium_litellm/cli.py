import argparse
import json
import sys
import time
from pathlib import Path

from .associations import ProtectedSnapshotSource, fields
from .controller import Controller
from .desired import Desired
from .errors import ControllerError, require
from .files import decode, read_bytes, validate_publication
from .ledger import Ledger
from .native import Native


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Reconcile only protected, isolated LiteLLM objects."
    )
    parser.add_argument("operation", choices=("init", "reconcile"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-rotate", action="store_true")
    parser.add_argument("--confirm-new-installation")
    args = parser.parse_args()
    try:
        config = decode(args.config.read_bytes())
        fields(
            config,
            {
                "schema_version",
                "environment",
                "installation",
                "issuer",
                "endpoint",
                "desired_state",
                "ownership_directory",
                "association_snapshot",
                "association_publisher_uid",
                "management_key_file",
                "backend_transports",
                "service_delivery",
                "service_association_snapshot",
                "bindings_snapshot",
            }
            | (
                {"publication_reader_gid"}
                if "publication_reader_gid" in config
                else set()
            ),
            "invalid_controller_configuration",
        )
        require(
            config["schema_version"] == 1 and config["environment"] == "isolated",
            "nonisolated_controller_refused",
        )
        ledger = Ledger(
            Path(config["ownership_directory"]),
            config["installation"],
            config["issuer"],
        )
        reader_gid = config.get("publication_reader_gid")
        if reader_gid is not None:
            for name in ("bindings_snapshot", "service_association_snapshot"):
                path = Path(config[name])
                custody = Path(config["ownership_directory"]).resolve()
                require(
                    not path.parent.resolve().is_relative_to(custody)
                    and not custody.is_relative_to(path.parent.resolve())
                    and not Path(config["management_key_file"])
                    .resolve()
                    .is_relative_to(path.parent.resolve()),
                    "publication_directory_overlaps_custody",
                )
                validate_publication(path, reader_gid)
        source = ProtectedSnapshotSource(
            Path(config["association_snapshot"]),
            config["installation"],
            config["issuer"],
            config["association_publisher_uid"],
        )
        if args.operation == "init":
            require(
                not args.dry_run
                and args.confirm_new_installation == config["installation"],
                "explicit_initialization_required",
            )
            source.read(int(time.time()))
            ledger.initialize()
            report = {
                "status": "initialized",
                "installation": config["installation"],
                "adoptions": 0,
            }
        else:
            require(
                args.confirm_new_installation is None,
                "initialization_not_reconciliation",
            )
            management_key = (
                read_bytes(
                    Path(config["management_key_file"]), secret=True, limit=16384
                )
                .decode()
                .strip()
            )
            native = Native(config["endpoint"], management_key)
            report = Controller(
                Desired.read(Path(config["desired_state"])),
                ledger,
                native,
                source,
                config["backend_transports"],
                service_delivery=config["service_delivery"],
                service_association_snapshot=Path(
                    config["service_association_snapshot"]
                ),
                bindings_snapshot=Path(config["bindings_snapshot"]),
                publication_reader_gid=reader_gid,
            ).run(dry_run=args.dry_run, rotate=not args.no_rotate)
        print(json.dumps(report, sort_keys=True))
        return 0
    except ControllerError as exc:
        print(json.dumps({"status": "failed", "code": exc.code}), file=sys.stderr)
        return 1
    except (OSError, UnicodeError):
        print(
            json.dumps({"status": "failed", "code": "controller_input_unavailable"}),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
