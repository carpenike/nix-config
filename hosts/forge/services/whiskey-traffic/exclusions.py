"""Maintain the "this is Ryan, not a visitor" IP exclusion for warwed.com traffic.

nix-config is a public repository, so the household's public IP is never
committed. Instead this runs on Forge (which sits at home) and:

1. Refreshes ``exclude-ips.auto`` (0600) with Forge's own public egress
   address: the IPv4 address and the IPv6 /64 prefix, as reported by
   Cloudflare's ``/cdn-cgi/trace`` on 1.1.1.1 (no new third party). A failed
   lookup keeps the previous value.
2. Merges it with the optional, hand-maintained ``exclude-ips.local`` (one
   entry per line: a literal IPv4/IPv6 address, or a prefix ending in ``.``
   or ``:`` such as ``203.0.113.`` / ``2001:db8:1:2:``; ``#`` comments).
3. Writes ``exclude-regex`` (0600): one full-match regex (LAN/loopback +
   the above) used by the weekly funnel report.
4. Renders the Grafana dashboard from its committed template with that regex
   as the ``exclude_ips`` variable default, into a root:grafana 0640 file
   that Grafana provisions from.

No address is ever printed to the journal; only counts.
"""

from __future__ import annotations

import argparse
import grp
import ipaddress
import json
import os
import re
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

LAN = [
    r"10\..*",
    r"192\.168\..*",
    r"172\.(1[6-9]|2[0-9]|3[01])\..*",
    r"127\..*",
    r"::1",
    r"f[cd][0-9a-f]{2}:.*",
    r"fe80:.*",
]
TRACE_V4 = "https://1.1.1.1/cdn-cgi/trace"
TRACE_V6 = "https://[2606:4700:4700::1111]/cdn-cgi/trace"
FETCH_ERRORS = (urllib.error.URLError, OSError, ValueError)


def atomic_write(path: Path, text: str, mode: int, gid: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.chmod(tmp, mode)
    if gid is not None:
        os.chown(tmp, 0, gid)
    os.replace(tmp, path)


def trace_ip(url: str, timeout: int) -> str | None:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            body = resp.read(4096).decode("ascii", "replace")
    except FETCH_ERRORS:
        return None
    for line in body.splitlines():
        if line.startswith("ip="):
            try:
                return str(ipaddress.ip_address(line[3:].strip()))
            except ValueError:
                return None
    return None


def refresh_auto(path: Path, timeout: int) -> dict:
    previous = {}
    if path.exists():
        try:
            previous = json.loads(path.read_text())
        except ValueError:
            previous = {}
    current = dict(previous)
    v4 = trace_ip(TRACE_V4, timeout)
    if (
        v4
        and ipaddress.ip_address(v4).version == 4
        and ipaddress.ip_address(v4).is_global
    ):
        current["ipv4"] = v4
    v6 = trace_ip(TRACE_V6, timeout)
    if (
        v6
        and ipaddress.ip_address(v6).version == 6
        and ipaddress.ip_address(v6).is_global
    ):
        net = ipaddress.ip_network(f"{v6}/64", strict=False)
        current["ipv6_prefix64"] = str(net.network_address)
    if current != previous:
        atomic_write(path, json.dumps(current, indent=2) + "\n", 0o600)
    print(
        f"auto exclusion: ipv4 {'set' if current.get('ipv4') else 'unset'}, "
        f"ipv6 /64 {'set' if current.get('ipv6_prefix64') else 'unset'}, "
        f"{'changed' if current != previous else 'unchanged'}"
    )
    return current


def entry_regex(entry: str) -> str | None:
    entry = entry.strip().lower()
    if not entry:
        return None
    if entry.endswith((".", ":")):
        if re.fullmatch(r"[0-9a-f.:]+", entry):
            return re.escape(entry) + ".*"
        return None
    try:
        return re.escape(str(ipaddress.ip_address(entry)))
    except ValueError:
        return None


def v6_prefix_regex(network_address: str) -> str:
    # 2001:db8:1:2:: -> "2001:db8:1:2:" ; addresses in Loki are compressed
    # (RFC 5952), so match the first four hextets as written.
    full = ipaddress.ip_address(network_address).exploded.split(":")[:4]
    hextets = [h.lstrip("0") or "0" for h in full]
    return re.escape(":".join(hextets) + ":") + ".*"


def build_regex(auto: dict, local_path: Path) -> tuple[str, int]:
    parts = list(LAN)
    extra = 0
    if auto.get("ipv4"):
        parts.append(re.escape(auto["ipv4"]))
        extra += 1
    if auto.get("ipv6_prefix64"):
        parts.append(v6_prefix_regex(auto["ipv6_prefix64"]))
        extra += 1
    if local_path.exists():
        for line in local_path.read_text().splitlines():
            rx = entry_regex(line.split("#", 1)[0])
            if rx:
                parts.append(rx)
                extra += 1
    return "^(" + "|".join(parts) + ")$", extra


def render_dashboard(template: Path, out: Path, regex: str, group: str) -> None:
    dash = json.loads(template.read_text())
    for var in dash.get("templating", {}).get("list", []):
        if var.get("name") == "exclude_ips":
            var["query"] = regex
            var["current"] = {"text": regex, "value": regex}
    try:
        gid = grp.getgrnam(group).gr_gid
    except KeyError:
        gid = None
    atomic_write(
        out, json.dumps(dash, indent=2) + "\n", 0o640 if gid is not None else 0o644, gid
    )


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--state-dir", required=True)
    p.add_argument("--template", required=True)
    p.add_argument("--dashboard-out", required=True)
    p.add_argument("--grafana-group", default="grafana")
    p.add_argument("--no-refresh", action="store_true", help="skip the egress lookup")
    p.add_argument("--timeout", type=int, default=10)
    args = p.parse_args()

    state = Path(args.state_dir)
    auto_path = state / "exclude-ips.auto"
    if args.no_refresh:
        auto = json.loads(auto_path.read_text()) if auto_path.exists() else {}
    else:
        auto = refresh_auto(auto_path, args.timeout)
    regex, extra = build_regex(auto, state / "exclude-ips.local")
    atomic_write(state / "exclude-regex", regex + "\n", 0o600)
    render_dashboard(
        Path(args.template), Path(args.dashboard_out), regex, args.grafana_group
    )
    print(
        f"exclusion regex: LAN/loopback + {extra} household entries; dashboard rendered"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
