"""Bounded real-runtime proof. No account login, model call, or production state."""

import base64
import http.client
import importlib.util
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import time


code, node, client, module, bash = sys.argv[1:]
root = Path.cwd() / "rb10-state"
root.mkdir(mode=0o700)
workspace = root / "workspaces" / "scratch"
workspace.mkdir(parents=True, mode=0o700)
runtime = root / "runtime"
runtime.mkdir(mode=0o700)
token = root / "connection-token"
token.write_text(secrets.token_urlsafe(48))
token.chmod(0o400)
env = {
    "PATH": os.environ["PATH"],
    "HOME": str(root),
    "SHELL": bash,
    "TMPDIR": str(runtime),
    "XDG_CONFIG_HOME": str(root / "config"),
    "XDG_DATA_HOME": str(root / "data"),
    "XDG_CACHE_HOME": str(root / "cache"),
    "VSCODE_CLI_DATA_DIR": str(root / "cli"),
    "VSCODE_AGENT_HOST_CLAUDE_AGENT_ENABLED": "false",
    "VSCODE_AGENT_HOST_CODEX_AGENT_ENABLED": "false",
    "PAGER": "cat",
}
# Nix's build sandbox lacks /etc/NIXOS and /sbin/ldconfig. The runtime is
# auto-patchelf'd; pass its actual loader for the upstream prerequisite check.
if "AGENT_HOST_TEST_LINKER" in os.environ:
    env["VSCODE_SERVER_CUSTOM_GLIBC_LINKER"] = os.environ["AGENT_HOST_TEST_LINKER"]

spec = importlib.util.spec_from_file_location(
    "healthcheck", Path(module) / "healthcheck.py"
)
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)
registry_dir = root / "user-data" / "agent-host" / "local-endpoint" / "entries"


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def run_client(entry, mode):
    subprocess.run(
        [node, client, str(entry), str(workspace), mode],
        env=env,
        check=True,
        timeout=40,
    )


def reject_unauthenticated(port, query):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request(
            "GET",
            "/" + query,
            headers={
                "Connection": "Upgrade",
                "Upgrade": "websocket",
                "Sec-WebSocket-Version": "13",
                "Sec-WebSocket-Key": base64.b64encode(secrets.token_bytes(16)).decode(
                    "ascii"
                ),
            },
        )
        check(
            connection.getresponse().status == 403,
            "Unauthenticated connection accepted",
        )
    finally:
        connection.close()


def start_and_check(round_number):
    log = (root / f"supervisor-{round_number}.log").open("wb")
    process = subprocess.Popen(
        [
            code,
            "--disable-telemetry",
            "--log",
            "warn",
            "agent",
            "host",
            "--foreground",
            "--new-instance",
            "--host",
            "127.0.0.1",
            "--port",
            "0",
            "--connection-token-file",
            str(token),
            "--server-data-dir",
            str(root / "server"),
            "--user-data-dir",
            str(root / "user-data"),
        ],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            check(process.poll() is None, "Host exited before readiness")
            entries = list(registry_dir.glob("*.json"))
            own_entries = []
            for entry in entries:
                try:
                    metadata = json.loads(entry.read_text())
                    if metadata["pid"] == process.pid:
                        own_entries.append((entry, metadata))
                except (OSError, ValueError, KeyError):
                    pass
            if len(own_entries) == 1:
                entry, metadata = own_entries[0]
                break
            time.sleep(0.2)
        else:
            raise AssertionError("No live endpoint registry entry")
        check(metadata["endpoint"]["host"] == "127.0.0.1", "Non-loopback listener")
        check(
            metadata["connectionToken"] == token.read_text(),
            "Wrong connection credential",
        )
        check(entry.stat().st_mode & 0o077 == 0, "Registry is not private")
        port = metadata["endpoint"]["port"]
        reject_unauthenticated(port, "")
        reject_unauthenticated(port, "?tkn=deliberately-invalid-fixture")

        result = subprocess.run(
            [
                code,
                "--log",
                "off",
                "--disable-telemetry",
                "agent",
                "ps",
                "--user-data-dir",
                str(root / "user-data"),
                "--json",
            ],
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        )
        check(
            health.valid_status(json.loads(result.stdout), port),
            "Protocol status is not ready",
        )
        if round_number == 1:
            run_client(entry, "dispatch")
            # There are now no connected clients. The host-native shell must
            # finish the coding/test fixture without anything serving tools.
            deadline = time.monotonic() + 20
            while (
                not (workspace / "completed.json").exists()
                and time.monotonic() < deadline
            ):
                time.sleep(0.2)
            evidence = json.loads((workspace / "completed.json").read_text())
            check(evidence["uid"] != 0, "Native task ran as root")
            check(evidence["answer"] == 42, "Native coding/test task failed")
            run_client(entry, "reconnect")
        else:
            check(
                (workspace / "completed.json").is_file(),
                "Workspace state disappeared on restart",
            )
            run_client(entry, "restart")
        print(
            f"Round {round_number}: loopback, token rejection, authenticated protocol passed"
        )
    finally:
        # Only our isolated process group, never a name-based process kill.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        finally:
            log.close()


check(os.getuid() != 0, "Run the fixture as an unprivileged user")
os.umask(0o077)
subprocess.run(
    [
        sys.executable,
        str(Path(module) / "preflight.py"),
        "--executable",
        code,
        "--version",
        "1.139.1",
        "--token-file",
        str(token),
    ],
    env=env,
    check=True,
    timeout=35,
)
(workspace / "coding_task.py").write_text(
    "import json, os\n"
    "from pathlib import Path\n"
    "Path('add.py').write_text('def add(a, b):\\n    return a + b\\n')\n"
    "from add import add\n"
    "assert add(20, 22) == 42\n"
    "assert add(-1, 1) == 0\n"
    "Path('completed.json').write_text(json.dumps({'uid': os.getuid(), 'answer': add(20, 22)}))\n"
    "print('NATIVE_TASK_OK', flush=True)\n"
)
start_and_check(1)
start_and_check(2)
print(
    "Pinned Agent Host smoke passed; provider login and AI-session lifecycle remain untested"
)
