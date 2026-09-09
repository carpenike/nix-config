"""Synthetic PKI inputs only; native TLS and authorization remain unmodified."""

import ipaddress
from datetime import UTC, datetime, timedelta

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


def key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def pem_key(value):
    return value.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )


def pem(value):
    return value.public_bytes(serialization.Encoding.PEM)


def certificate(
    subject, private, *, issuer=None, issuer_key=None, ca=False, names=(), client=False
):
    issuer_key = issuer_key or private
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject)])
    now = datetime.now(UTC)
    builder = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(issuer.subject if issuer is not None else name)
        .public_key(private.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=1))
        .not_valid_after(now + timedelta(days=1))
        .add_extension(
            x509.BasicConstraints(ca=ca, path_length=1 if ca else None), critical=True
        )
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=not ca,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=ca,
                crl_sign=ca,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.SubjectKeyIdentifier.from_public_key(private.public_key()),
            critical=False,
        )
        .add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_key.public_key()),
            critical=False,
        )
    )
    if not ca:
        builder = builder.add_extension(
            x509.ExtendedKeyUsage(
                [
                    ExtendedKeyUsageOID.CLIENT_AUTH
                    if client
                    else ExtendedKeyUsageOID.SERVER_AUTH,
                ]
            ),
            critical=True,
        )
    if names:
        entries = []
        for value in names:
            try:
                entries.append(x509.IPAddress(ipaddress.ip_address(value)))
            except ValueError:
                entries.append(x509.DNSName(value))
        builder = builder.add_extension(
            x509.SubjectAlternativeName(entries), critical=False
        )
    return builder.sign(issuer_key, hashes.SHA256())


def material(fixture):
    result = {}
    authorities = {}
    for name in (
        "front",
        "native",
        "resolver-client",
        "device",
        "policy",
        "policy-client",
    ):
        private = key()
        cert = certificate("n03-" + name, private, ca=True)
        authorities[name] = private, cert
        result[name + "-ca"] = pem(cert)
        result[name + "-ca-key"] = pem_key(private)
    for name, authority, names, client in (
        ("front", "front", tuple(fixture["names"].values()), False),
        ("registration", "front", (fixture["names"]["registration"],), False),
        ("server", "native", (fixture["names"]["native"], "127.0.0.1"), False),
        ("native-client", "resolver-client", (), True),
        ("wrong-native-client", "resolver-client", (), True),
        ("policy-server", "policy", ("127.0.0.1",), False),
        ("policy-client", "policy-client", (), True),
        ("wrong-policy-client", "policy-client", (), True),
    ):
        private = key()
        signer, issuer = authorities[authority]
        cert = certificate(
            "n03-" + name,
            private,
            issuer=issuer,
            issuer_key=signer,
            names=names,
            client=client,
        )
        result[name + "-cert"] = pem(cert)
        result[name + "-key"] = pem_key(private)
    return result
