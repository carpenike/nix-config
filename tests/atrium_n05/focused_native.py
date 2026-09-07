"""Run existing pytest tests with signing fixtures confined to native /run tmpfs."""

import argparse
import base64
import hashlib
import importlib.metadata
import io
import json
import secrets
import subprocess
from pathlib import Path
from zipfile import ZipFile

from actual_native import PRODUCT
from supervisor import ROOT, git, inventory, load_harness, ready, verified_wheels

TESTS = (
    "test_admission.py",
    "test_request_context.py",
    "test_bootstrap.py",
    "test_probe.py",
    "test_artifacts.py",
)
BOOT = """
import base64,contextlib,importlib.metadata,io,json,logging,os,pathlib,sys,zipfile
root=pathlib.Path("/run/atrium-n05-focused")
data=json.loads(sys.stdin.readline())
os.environ.update(
 PYTEST_DISABLE_PLUGIN_AUTOLOAD="1", PYTHONDONTWRITEBYTECODE="1",
 TMPDIR=str(root), LITELLM_LOCAL_MODEL_COST_MAP="True",
 LITELLM_TELEMETRY="False", DO_NOT_TRACK="1", LITELLM_LOG="ERROR",
)
for encoded in data["wheels"].values():
 with zipfile.ZipFile(io.BytesIO(base64.b64decode(encoded))) as wheel:
  wheel.extractall(root/"python")
with zipfile.ZipFile(io.BytesIO(base64.b64decode(data["pytest"]))) as packages:
 packages.extractall(root/"python")
for name,text in data["files"].items():
 path=root/name
 path.parent.mkdir(parents=True,exist_ok=True)
 path.write_text(text)
sys.path.insert(0,str(root/"python"))
sys.path.insert(0,str(root/"tests/atrium_n05"))
os.chdir(root)
logging.disable(logging.CRITICAL)
import pytest
version=importlib.metadata.version("litellm")
assert version=="1.99.1"
class Summary:
 def pytest_sessionfinish(self,session,exitstatus):
  reporter=session.config.pluginmanager.get_plugin("terminalreporter")
  self.counts={name:len(items) for name,items in reporter.stats.items() if name}
summary=Summary()
output=io.StringIO()
with contextlib.redirect_stdout(output),contextlib.redirect_stderr(output):
 status=pytest.main(["-q","--tb=short","-p","no:cacheprovider",
  "--basetemp",str(root/"cases"),*data["tests"]],plugins=[summary])
result={"exit_code":int(status),"counts":getattr(summary,"counts",{}),"litellm_version":version}
if status:
 result["diagnostic"]=output.getvalue()
print(json.dumps(result))
raise SystemExit(int(status))
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    _, harness_hashes = load_harness(args.harness)
    from harness.common import EvidenceWriter, PINS, require
    from harness.containers import Resources

    require(
        args.evidence.resolve().is_relative_to(ROOT / "tests/atrium_n05/results"),
        "evidence_path_refused",
    )
    require(not args.evidence.exists(), "existing_evidence_refused")
    wheels, wheel_hashes = verified_wheels(args.harness, PRODUCT)
    archive = io.BytesIO()
    versions = {}
    with ZipFile(archive, "w") as output:
        for name in ("pytest", "pluggy", "iniconfig", "packaging", "pygments"):
            distribution = importlib.metadata.distribution(name)
            versions[name] = distribution.version
            for relative in distribution.files:
                if ".." not in relative.parts and relative.suffix != ".pyc":
                    output.write(distribution.locate_file(relative), str(relative))
    files = {
        "tests/atrium_n05/" + path.name: path.read_text()
        for path in (ROOT / "tests/atrium_n05").glob("*.py")
    }
    files["fixtures/policy.generated.json"] = git(
        args.harness, "show", PRODUCT + ":resolver/fixtures/policy.generated.json"
    ).decode()
    result = {
        "ticket": "ATR-N05",
        "run_id": "n05-focused-" + secrets.token_hex(6),
        "status": "running",
        "scope": "focused tests; not native HTTP gate evidence",
        "source": {
            "commit": git(ROOT, "rev-parse", "HEAD").decode().strip(),
            "dirty": bool(git(ROOT, "status", "--porcelain").strip()),
            "product_revision": PRODUCT,
            "wheel_sha256": wheel_hashes,
            "shared_harness": harness_hashes,
            "test_dependencies": versions,
            "test_dependency_archive_sha256": hashlib.sha256(
                archive.getvalue()
            ).hexdigest(),
            "files": {
                name: {
                    "algorithm": "sha256",
                    "digest": hashlib.sha256(text.encode()).hexdigest(),
                }
                for name, text in files.items()
            },
        },
        "tests": ["tests/atrium_n05/" + name for name in TESTS],
    }
    writer = EvidenceWriter(args.evidence, result)
    resources = Resources(result["run_id"], result, writer.publish)
    before = ready(resources)
    result["foreign_before"] = before
    try:
        arch = json.loads(resources.command(["info", "--format", "json"]))["host"][
            "arch"
        ]
        image = resources.image(PINS["litellm"]["image"], "linux/" + arch)
        require(
            "ghcr.io/berriai/litellm@" + PINS["litellm"]["platform_manifests"][arch]
            in image["repo_digests"],
            "pinned_platform_mismatch",
        )
        result["image"] = image
        identifier = resources.create(
            "pytest",
            image["image_id"],
            "python",
            ["-B", "-c", BOOT],
            memory="1536m",
            network=False,
            options=(
                "--tmpfs",
                "/run/atrium-n05-focused:rw,nosuid,nodev,noexec,size=128m,mode=0700",
            ),
        )
        process = subprocess.run(
            [
                *resources.prefix_command,
                "start",
                "--attach",
                "--interactive",
                identifier,
            ],
            input=json.dumps(
                {
                    "wheels": wheels,
                    "pytest": base64.b64encode(archive.getvalue()).decode(),
                    "files": files,
                    "tests": result["tests"],
                }
            )
            + "\n",
            text=True,
            capture_output=True,
            timeout=180,
            check=False,
        )
        result["pytest"] = json.loads(process.stdout)
        result["status"] = "passed" if process.returncode == 0 else "failed"
    finally:
        resources.cleanup()
        after = inventory(resources)
        result["foreign_after"] = after
        result["foreign_resources_unchanged"] = before == after
        require(result["foreign_resources_unchanged"], "foreign_resource_changed")
        writer.publish()
    print(
        json.dumps(
            {
                "status": result["status"],
                "pytest": result["pytest"],
                "evidence": str(args.evidence),
            }
        )
    )
    return 0 if result["status"] == "passed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
