"""Inject the actual controller into N07's unmodified, pinned native lifecycle."""

import argparse
import hashlib
import json
import os
import secrets
import signal
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOADER = """
import importlib,json,os,pathlib,sys,traceback
data=json.loads(sys.stdin.readline())
root=pathlib.Path("/run/atrium-n04")
os.chdir(root)
for name,source in data.pop("sources").items():
 p=pathlib.Path("code")/name
 p.parent.mkdir(parents=True,exist_ok=True)
 p.write_text(source)
sys.path.insert(0,str(root/"code"))
try:
 from native_cases import run
 result=run(data)
except Exception as exc:
 from atrium_litellm.errors import ControllerError
 frames=traceback.extract_tb(exc.__traceback__)
 result={"status":"failed","code":exc.code if isinstance(exc,ControllerError) else "unexpected_fixture_failure",
         "error_type":type(exc).__name__,"locations":[{"file":pathlib.Path(f.filename).name,"line":f.lineno} for f in frames[-5:]]}
print(json.dumps(result,sort_keys=True))
"""


def command(args):
    completed = subprocess.run(
        args, cwd=ROOT, capture_output=True, text=True, timeout=120, check=False
    )
    if completed.returncode:
        raise RuntimeError("source_command_failed")
    return completed.stdout.strip()


def source_identity(spec, harness):
    paths = [
        *sorted((ROOT / "pkgs/atrium-litellm-controller").rglob("*.py")),
        *sorted((ROOT / "tests/atrium_n04").glob("*.py")),
        ROOT / "tests/atrium_n04/fixture.nix",
        ROOT / "pkgs/atrium-litellm-controller/default.nix",
        ROOT / "pkgs/atrium-litellm-controller/pyproject.toml",
    ]
    return {
        "component_commit": command(["git", "rev-parse", "HEAD"]),
        "component_branch": command(["git", "branch", "--show-current"]),
        "source_sha256": {
            str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in paths
        },
        "owner_spec_sha256": hashlib.sha256(spec.read_bytes()).hexdigest(),
        "harness_commit": command(["git", "-C", str(harness), "rev-parse", "HEAD"]),
        "harness_sha256": {
            name: hashlib.sha256((harness / "harness" / name).read_bytes()).hexdigest()
            for name in (
                "containers.py",
                "litellm_native.py",
                "provider.py",
                "pins.json",
            )
        },
        "resolver_uv_lock_sha256": hashlib.sha256(
            (harness / "resolver/uv.lock").read_bytes()
        ).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.harness.resolve()))
    from harness import litellm_native as native
    from harness.common import EvidenceWriter, HarnessError, require
    from harness.containers import Resources

    output = args.evidence.resolve()
    require(
        output.is_relative_to(ROOT / "tests/atrium_n04/results"),
        "evidence_path_refused",
    )
    run_id = "n04-" + secrets.token_hex(8)
    result = {
        "schema_version": 1,
        "ticket": "ATR-N04",
        "run_id": run_id,
        "status": "running",
        "source": source_identity(args.spec, args.harness.resolve()),
        "full_phase1_gate": "blocked",
    }
    writer = EvidenceWriter(output, result)
    generated = json.loads(
        command(
            [
                "nix",
                "eval",
                "--offline",
                "--no-write-lock-file",
                "--option",
                "allow-import-from-derivation",
                "false",
                "--impure",
                "--json",
                "--expr",
                "(import ./tests/atrium_n04/fixture.nix { atrium = "
                "(builtins.getFlake (toString ./.)).inputs.atrium; }).litellm",
            ]
        )
    )
    result["source"]["generated_desired_sha256"] = hashlib.sha256(
        json.dumps(generated, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    require(
        result["source"]["harness_commit"]
        == "d373d7c6b6d944b2e09eb93ad540803c10fdf206",
        "unexpected_harness_revision",
    )
    require(
        "### A.3 LiteLLM" in args.spec.read_text()
        and "### C2" in args.spec.read_text(),
        "current_self_contained_spec_required",
    )
    fixture = {}
    base_configuration = native.configuration

    class ObservedResources(Resources):
        def __init__(self, *params, **options):
            super().__init__(*params, **options)
            fixture["resources"] = self

        def inventory(self):
            return {
                parts[0]: {"name": parts[1], "state": parts[2]}
                for line in self.command(
                    ["ps", "--all", "--format", "{{.ID}}|{{.Names}}|{{.State}}"]
                ).splitlines()
                if len(parts := line.split("|")) == 3
            }

        def select_local_engine(self):
            super().select_local_engine()
            self.result["foreign_resources_before"] = self.inventory()

        def cleanup(self):
            super().cleanup()
            if "foreign_resources_before" not in self.result:
                return
            after = self.inventory()
            self.result["foreign_resources_after"] = {
                identity: after.get(identity)
                for identity in self.result["foreign_resources_before"]
            }
            self.result["foreign_resources_unchanged"] = (
                self.result["foreign_resources_after"]
                == self.result["foreign_resources_before"]
            )
            self.publish()
            require(
                self.result["foreign_resources_unchanged"],
                "preexisting_resource_state_changed",
            )

        def start(self, identifier, payload=""):
            role = next(
                item["role"]
                for item in self.result["resources"]
                if item.get("id") == identifier
            )
            if role == "litellm":
                fixture["runtime_environment"] = json.loads(payload)["environment"]
            return super().start(identifier, payload)

    def configuration(provider):
        config = base_configuration(provider)
        config["general_settings"]["store_model_in_db"] = True
        config["router_settings"]["max_fallbacks"] = 0
        return config

    def exercise(
        client, observer, control, observer_headers, evidence, invocation, checkpoint
    ):
        resources = fixture["resources"]
        family_key = secrets.token_urlsafe(32)
        family_provider = resources.create(
            "family-provider",
            evidence["images"]["litellm"]["image_id"],
            "python",
            ["-B", "-c", (args.harness / "harness/provider.py").read_text()],
            memory="256m",
            port=8000,
        )
        resources.start(
            family_provider,
            json.dumps(
                {
                    "inference": family_key,
                    "observer": observer_headers["Authorization"].removeprefix(
                        "Bearer "
                    ),
                }
            ),
        )
        resources.wait_running(family_provider)
        import httpx

        with httpx.Client(
            base_url=resources.endpoint(family_provider, 8000),
            trust_env=False,
            timeout=10,
        ) as family:
            native.wait_http(family, "/_fixture/counts", observer_headers, seconds=30)
        sources = {
            "atrium_litellm/" + p.name: p.read_text()
            for p in sorted(
                (ROOT / "pkgs/atrium-litellm-controller/atrium_litellm").glob("*.py")
            )
        }
        for name in ("native_cases.py", "native_consumer.py"):
            sources[name] = (ROOT / "tests/atrium_n04" / name).read_text()
        child = resources.create(
            "controller",
            evidence["images"]["litellm"]["image_id"],
            "python",
            ["-B", "-c", LOADER],
            memory="768m",
            options=(
                "--tmpfs",
                "/run/atrium-n04:rw,nosuid,nodev,noexec,size=32m,mode=0755",
            ),
        )
        data = {
            "sources": sources,
            "desired": generated,
            "installation": invocation,
            "endpoint": "http://" + resources.prefix + "-litellm:4000",
            "provider": resources.prefix + "-provider",
            "family_provider": resources.prefix + "-family-provider",
            "management_key": fixture["runtime_environment"]["LITELLM_MASTER_KEY"],
            "provider_key": fixture["runtime_environment"]["SYNTHETIC_PROVIDER_KEY"],
            "family_provider_key": family_key,
            "observer_key": observer_headers["Authorization"].removeprefix("Bearer "),
        }
        argv = [*resources.prefix_command, "start", "--attach", "--interactive", child]
        operation = {
            "argv": argv,
            "status": "running",
            "stdin": "not recorded; actual source and runtime secrets",
        }
        evidence["commands"].append(operation)
        checkpoint()
        completed = subprocess.run(
            argv,
            cwd=ROOT,
            input=json.dumps(data) + "\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=600,
            check=False,
        )
        operation.update(
            status="passed" if completed.returncode == 0 else "failed",
            exit_code=completed.returncode,
        )
        require(completed.returncode == 0, "controller_fixture_process_failed")
        try:
            observed = json.loads(completed.stdout)
        except json.JSONDecodeError:
            raise HarnessError("controller_fixture_output_invalid") from None
        evidence["controller"] = observed
        evidence["scope"].update(
            {
                "native_only": False,
                "owned_controller": True,
                "admission_hook": False,
                "resolver_broker": False,
                "service_consumer": "running native-consumer fixture, not Whiskey W03",
            }
        )
        checkpoint()
        require(observed.get("status") == "passed", "owned_controller_cases_failed")
        evidence["cases"] = observed["cases"]

    def interrupt(_number, _frame):
        raise KeyboardInterrupt

    for name in ("SIGINT", "SIGTERM"):
        signal.signal(getattr(signal, name), interrupt)
    # These are orchestration extension points only. Native authentication, HTTP,
    # model routing, controller logic, and the provider are never replaced.
    native.Resources, native.configuration, native.exercise = (
        ObservedResources,
        configuration,
        exercise,
    )
    try:
        native.run(result, run_id, checkpoint=writer.publish)
        result["status"] = "passed"
    except (HarnessError, RuntimeError) as exc:
        result["status"] = "failed"
        result["code"] = (
            exc.code if isinstance(exc, HarnessError) else "source_command_failed"
        )
    except (OSError, subprocess.TimeoutExpired):
        result.update(status="failed", code="fixture_process_unavailable")
    except KeyboardInterrupt:
        result.update(status="interrupted", code="fixture_interrupted")
    finally:
        writer.publish()
    print(
        json.dumps(
            {
                "status": result["status"],
                "evidence": str(output.relative_to(ROOT)),
                "controller": result.get("controller", {}),
                "cleanup": result.get("cleanup", {"status": "not-started"}),
            },
            sort_keys=True,
        )
    )
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    sys.exit(main())
