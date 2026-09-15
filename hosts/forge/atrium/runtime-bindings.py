"""Bind static deployment templates to actual operator-provisioned public TLS leaves."""

import argparse
import json
import os
import shlex
import stat
from datetime import UTC, datetime
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.x509.oid import ExtendedKeyUsageOID


def read_json(path):
    data = path.read_bytes()
    if len(data) > 1024 * 1024:
        raise ValueError("oversized configuration")
    return json.loads(data)


def fingerprint(path):
    certificate = x509.load_pem_x509_certificate(path.read_bytes())
    constraints = certificate.extensions.get_extension_for_class(
        x509.BasicConstraints
    ).value
    usage = certificate.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value
    if (
        constraints.ca
        or ExtendedKeyUsageOID.CLIENT_AUTH not in usage
        or not certificate.not_valid_before_utc
        <= datetime.now(UTC)
        < certificate.not_valid_after_utc
    ):
        raise ValueError("invalid client leaf")
    return certificate.fingerprint(hashes.SHA256()).hex()


def publish(path, content):
    parent = path.parent
    metadata = parent.lstat()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o077
    ):
        raise ValueError("private output directory required")
    pending = parent / (path.name + ".new")
    descriptor = os.open(
        pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(pending, path)
        descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        pending.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "kind", choices=("native-policy", "native-environment", "whiskey-images")
    )
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--client-certificate", type=Path)
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        template = read_json(args.template)
        peer = (
            None
            if args.kind == "whiskey-images"
            else fingerprint(args.client_certificate)
        )
        if args.kind == "native-policy":
            adapters = template["native_policy"]["adapters"]
            if len(adapters) != 1 or adapters[0]["certificates"] != []:
                raise ValueError("unexpected native policy template")
            adapters[0]["certificates"] = [peer]
            content = json.dumps(template, sort_keys=True) + "\n"
        elif args.kind == "native-environment":
            profile = read_json(args.profile or Path(template["profile_path"]))
            if profile["resource"] != template["resource"]:
                raise ValueError("operator native target disagrees with Nix")
            issuance = template["issuance"]
            if issuance["tls"]["resolver_certificates"] != []:
                raise ValueError("unexpected native issuance template")
            issuance["tls"]["resolver_certificates"] = [peer]
            values = {
                "HOMELAB_MCP_ATRIUM_NATIVE": profile,
                "HOMELAB_MCP_ATRIUM_ISSUANCE": issuance,
                "HOMELAB_MCP_ATRIUM_POLICY": template["policy"],
                "HOMELAB_MCP_ATRIUM_DENY": template["deny"],
            }
            content = "".join(
                name
                + "="
                + shlex.quote(json.dumps(value, separators=(",", ":")))
                + "\n"
                for name, value in values.items()
            )
        else:
            if set(template) != {
                "OPENAI_API_KEY",
                "GEMINI_API_KEY",
                "OPENROUTER_API_KEY",
            }:
                raise ValueError("unexpected image credential sources")
            values = {}
            for name, path in template.items():
                value = Path(path).read_text(encoding="utf-8").strip()
                if (
                    not value
                    or len(value) > 16384
                    or any(char in value for char in "\n\r\x00")
                ):
                    raise ValueError("invalid image credential")
                values[name] = value
            content = "".join(
                name + "=" + shlex.quote(value) + "\n" for name, value in values.items()
            )
        publish(args.output, content)
    except Exception:
        raise SystemExit("atrium_runtime_bindings_rejected") from None


if __name__ == "__main__":
    main()
