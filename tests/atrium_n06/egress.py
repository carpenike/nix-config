"""Address-level egress policy for an invocation-owned Linux network namespace."""

import argparse
import ipaddress
import json
import os
import re
import subprocess
from pathlib import Path

TABLE = "atrium_whiskey"


def require(condition, code):
    if not condition:
        raise ValueError(code)


def render(policy, bindings):
    require(
        set(policy) == {"schema_version", "isolated", "service_uid", "destinations"},
        "policy_fields",
    )
    require(
        policy["schema_version"] == 1 and policy["isolated"] is True,
        "isolated_policy_required",
    )
    uid = policy["service_uid"]
    require(type(uid) is int and 1000 <= uid < 2**31, "service_uid_refused")
    destinations = policy["destinations"]
    require(
        isinstance(destinations, dict) and bool(destinations), "destinations_required"
    )
    require(set(bindings) == set(destinations), "exact_destination_bindings_required")
    lines = [
        f"table inet {TABLE} {{",
        " chain output {",
        "  type filter hook output priority 0; policy accept;",
        f"  meta skuid {uid} ct direction reply counter accept",
    ]
    for name, destination in sorted(destinations.items()):
        require(re.fullmatch(r"[a-z][a-z0-9-]{0,63}", name), "destination_id_refused")
        require(
            set(destination) == {"hosts", "ports", "kind"}
            and destination["kind"] in ("gateway", "provider-exception", "non-model"),
            "destination_fields",
        )
        require(
            isinstance(destination["hosts"], list)
            and destination["hosts"]
            and all(
                isinstance(host, str) and re.fullmatch(r"[a-z0-9.-]+", host)
                for host in destination["hosts"]
            ),
            "destination_hosts_refused",
        )
        ports = destination["ports"]
        require(
            isinstance(ports, list)
            and ports
            and all(type(port) is int and 1 <= port <= 65535 for port in ports),
            "destination_ports_refused",
        )
        addresses = bindings[name]
        require(
            isinstance(addresses, list) and addresses, "destination_addresses_required"
        )
        for address in sorted(set(addresses)):
            ip = ipaddress.IPv4Address(address)
            require(
                str(ip) == address
                and not (ip.is_loopback or ip.is_multicast or ip.is_unspecified),
                "destination_address_refused",
            )
            lines.append(
                f'  meta skuid {uid} ip daddr {ip} tcp dport {{ {", ".join(map(str, sorted(set(ports))))} }} counter accept comment "{name}"'
            )
    lines.extend(
        [
            f"  meta skuid {uid} counter reject with icmpx type admin-prohibited",
            " }",
            "}",
        ]
    )
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--bindings", type=Path, required=True)
    parser.add_argument("--expected-netns", required=True)
    parser.add_argument("--nft", type=Path, required=True)
    args = parser.parse_args()
    require(os.geteuid() == 0, "namespace_setup_uid_required")
    require(
        re.fullmatch(r"net:\[[0-9]+\]", args.expected_netns),
        "namespace_identity_refused",
    )
    require(
        os.readlink("/proc/self/ns/net") == args.expected_netns,
        "namespace_identity_mismatch",
    )
    policy = json.loads(args.policy.read_text())
    rules = render(policy, json.loads(args.bindings.read_text()))
    existing = subprocess.run(
        [str(args.nft), "list", "table", "inet", TABLE],
        capture_output=True,
        check=False,
    )
    require(existing.returncode != 0, "existing_egress_table_refused")
    for options in (["--check"], []):
        applied = subprocess.run(
            [str(args.nft), *options, "--file", "-"],
            input=rules,
            text=True,
            capture_output=True,
            check=False,
        )
        require(applied.returncode == 0, "namespace_egress_installation_failed")
    print(
        json.dumps(
            {
                "installed": True,
                "netns": args.expected_netns,
                "uid": policy["service_uid"],
                "table": TABLE,
                "granularity": "destination IPv4 address and TCP port",
            }
        )
    )


if __name__ == "__main__":
    main()
