import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "pkgs/atrium-litellm-controller"))


@pytest.fixture(scope="session")
def generated():
    if path := os.environ.get("ATRIUM_N04_GENERATED_FIXTURE"):
        return json.loads(Path(path).read_bytes())
    output = subprocess.run(
        [
            "nix",
            "eval",
            "--builders",
            "",
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
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert output.returncode == 0, "N02 fixture producer failed"
    return json.loads(output.stdout)
