"""Authenticate through the private registry; never print tokens/session data."""

import argparse
import json
import subprocess
import sys
import time


FAILURE_REASONS = {
    "TIMEOUT": "authenticated status query timed out",
    "CLI_UNAVAILABLE": "status CLI is unavailable or cannot be executed",
    "STATUS_QUERY_FAILED": "status command failed; check host lifecycle, private registry and connection authentication",
    "INVALID_STATUS": "status is not valid JSON for one expected standalone loopback host with a successful session list",
}


def valid_status(status, port):
    if not isinstance(status, list) or len(status) != 1:
        return False
    entry = status[0]
    if not isinstance(entry, dict) or "error" in entry:
        return False
    host = entry.get("host", {})
    return (
        isinstance(host, dict)
        and host.get("type") == "standalone"
        and host.get("address") == f"127.0.0.1:{port}"
        and isinstance(entry.get("sessions"), list)
    )


def probe(executable, data_dir, port, timeout):
    result = subprocess.run(
        [
            executable,
            "--log",
            "off",
            "--disable-telemetry",
            "--cli-data-dir",
            f"{data_dir}/cli",
            "agent",
            "ps",
            "--user-data-dir",
            f"{data_dir}/user-data",
            "--json",
        ],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=True,
    )
    return valid_status(json.loads(result.stdout), port)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", required=True)
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--attempts", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=10)
    args = parser.parse_args()
    code = "INVALID_STATUS"
    for attempt in range(args.attempts):
        code = "INVALID_STATUS"
        try:
            if probe(args.executable, args.data_dir, args.port, args.timeout):
                print(
                    "Agent Host transport ready; provider authentication is not checked"
                )
                return 0
        except subprocess.TimeoutExpired:
            code = "TIMEOUT"
        except subprocess.SubprocessError:
            code = "STATUS_QUERY_FAILED"
        except OSError:
            code = "CLI_UNAVAILABLE"
        except ValueError:
            code = "INVALID_STATUS"
        if attempt + 1 < args.attempts:
            time.sleep(1)
    # Last attempt's fixed category only; upstream errors may contain bearer URLs.
    print(
        f"Agent Host authenticated transport check failed [{code}]: {FAILURE_REASONS[code]}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
