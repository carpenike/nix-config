"""Resolve only declared destinations and atomically replace Whiskey's IPv4 rules."""

import argparse
import ipaddress
import json
import re
import socket
import subprocess
from pathlib import Path


def require(condition, code):
    if not condition:
        raise ValueError(code)


def address(value):
    parsed = ipaddress.IPv4Address(value)
    require(
        str(parsed) == value
        and not (parsed.is_unspecified or parsed.is_multicast or parsed.is_loopback),
        "invalid_destination_address",
    )
    return value


def resolve(configuration):
    require(
        set(configuration) == {"hosts", "dns_addresses", "uid"},
        "invalid_network_fields",
    )
    require(
        type(configuration["uid"]) is int and configuration["uid"] > 0,
        "invalid_network_identity",
    )
    hosts = configuration["hosts"]
    require(
        isinstance(hosts, list)
        and hosts
        and len(hosts) == len(set(hosts))
        and all(
            isinstance(host, str)
            and re.fullmatch(r"[a-z0-9][a-z0-9.-]*\.[a-z][a-z0-9-]*", host)
            for host in hosts
        ),
        "exact_destination_hosts_required",
    )
    require(configuration["dns_addresses"], "dns_resolvers_required")
    dns = [address(value) for value in configuration["dns_addresses"]]
    destinations = {}
    for host in hosts:
        answers = sorted(
            {
                address(row[4][0])
                for row in socket.getaddrinfo(
                    host, 443, socket.AF_INET, socket.SOCK_STREAM
                )
            }
        )
        require(answers, "destination_resolution_empty")
        destinations[host] = answers
    return destinations, dns


def rules(destinations, dns):
    lines = [
        "*filter",
        ":ATRIUM-WHISKEY - [0:0]",
        "-F ATRIUM-WHISKEY",
        "-A ATRIUM-WHISKEY -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN",
    ]
    for value in sorted({item for values in destinations.values() for item in values}):
        lines.append(
            f"-A ATRIUM-WHISKEY -p tcp -d {address(value)} --dport 443 -j RETURN"
        )
    for value in sorted(set(dns)):
        for protocol in ("udp", "tcp"):
            lines.append(
                f"-A ATRIUM-WHISKEY -p {protocol} -d {address(value)} --dport 53 -j RETURN"
            )
    return "\n".join([*lines, "-A ATRIUM-WHISKEY -j REJECT", "COMMIT", ""])


def execute(command, *, body=None, allowed=(0,)):
    result = subprocess.run(
        command,
        input=body,
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )
    require(result.returncode in allowed, "network_command_failed")
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--iptables-restore", required=True)
    parser.add_argument("--iptables", required=True)
    parser.add_argument("--ip6tables", required=True)
    args = parser.parse_args()
    try:
        configuration = json.loads(args.config.read_bytes())
        destinations, dns = resolve(configuration)
        rendered = rules(destinations, dns)
        execute([args.iptables_restore, "--wait", "--test", "--noflush"], body=rendered)
        execute([args.iptables_restore, "--wait", "--noflush"], body=rendered)
        for executable, target in (
            (args.iptables, "ATRIUM-WHISKEY"),
            (args.ip6tables, "REJECT"),
        ):
            rule = [
                "OUTPUT",
                "-m",
                "owner",
                "--uid-owner",
                str(configuration["uid"]),
                "-j",
                target,
            ]
            if execute([executable, "-w", "-C", *rule], allowed=(0, 1)) == 1:
                execute([executable, "-w", "-I", *rule])
        print(
            json.dumps(
                {
                    "installed": True,
                    "hosts": len(destinations),
                    "addresses": len(
                        {item for values in destinations.values() for item in values}
                    ),
                    "enforcement": "ipv4-address-and-port",
                    "undeclared_hosts_added": False,
                },
                sort_keys=True,
            )
        )
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        raise SystemExit(
            "atrium_whiskey_network_rejected:resolution_or_installation_failed"
        ) from None


if __name__ == "__main__":
    main()
