"""Finite non-actuating provider contracts for the immutable native Whiskey clients."""

import base64
import hashlib
import json
import secrets
import time
from datetime import datetime, timezone
from email import policy
from email.parser import BytesParser
from urllib.parse import parse_qs, urlsplit

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

IDENTITY = "https://identity.atrium.invalid"
RESOURCE = "https://whiskey.atrium.invalid/api/mcp"
FIRESTORE = "/v1/projects/getpartiful/databases/(default)/documents/events/"
GROUP = "00000000-0000-4000-8000-000000000001"


def encoded(body):
    return base64.urlsafe_b64encode(body).decode().rstrip("=")


class RequiredFeatures:
    def __init__(self, credentials, signing_key, partiful_token, png, decrypt_push):
        self.credentials = credentials
        self.partiful_token = partiful_token
        self.png = png
        self.decrypt_push = decrypt_push
        self.signup_active = False
        self.event = {
            "name": {"stringValue": "Synthetic N06 event"},
            "startDate": {"timestampValue": "2031-07-01T18:00:00.000Z"},
            "endDate": {"timestampValue": "2031-07-01T21:00:00.000Z"},
            "timezone": {"stringValue": "UTC"},
        }
        self.jwk = json.loads(
            jwt.algorithms.RSAAlgorithm.to_jwk(signing_key.public_key())
        )
        self.jwk.update(kid="n06-external", alg="RS256", use="sig")
        now = int(time.time())
        claims = {
            "iss": IDENTITY,
            "aud": RESOURCE,
            "sub": "n06-synthetic-user",
            "iat": now,
            "exp": now + 1800,
            "jti": secrets.token_hex(16),
            "client_id": "n06-native-client",
            "scope": "n06-read",
        }
        self.tokens = {}
        for variant, update in {
            "valid": {},
            "wrong-audience": {"aud": "https://foreign.atrium.invalid"},
            "wrong-issuer": {"iss": "https://foreign.atrium.invalid"},
            "missing-scope": {"scope": "unrelated"},
            "expired": {"iat": now - 600, "exp": now - 120},
        }.items():
            self.tokens[variant] = jwt.encode(
                claims | update,
                signing_key,
                algorithm="RS256",
                headers={"typ": "at+jwt", "kid": "n06-external"},
            )
        header, body, signature = self.tokens["valid"].split(".")
        self.tokens["tampered"] = ".".join(
            (
                header,
                body,
                ("A" if signature[0] != "A" else "B") + signature[1:],
            )
        )
        self.receiver_key = ec.generate_private_key(ec.SECP256R1())
        self.receiver_auth = secrets.token_bytes(16)

    def private_bootstrap(self):
        return {
            "external_tokens": self.tokens,
            "push_subscription": {
                "endpoint": "https://push.atrium.invalid/fixture/subscription",
                "p256dh": encoded(
                    self.receiver_key.public_key().public_bytes(
                        serialization.Encoding.X962,
                        serialization.PublicFormat.UncompressedPoint,
                    )
                ),
                "auth": encoded(self.receiver_auth),
            },
        }

    @staticmethod
    def result(
        status, body, *, effect=None, content_type="application/json", **observed
    ):
        return {
            "status": status,
            "body": body,
            "content_type": content_type,
            "effect": effect,
            "observed": observed,
        }

    def authorized(self, headers, kind, scheme="Bearer "):
        return secrets.compare_digest(
            headers.get("Authorization", ""),
            scheme
            + (self.partiful_token if kind == "partiful" else self.credentials[kind]),
        )

    def handle(self, host, method, target, headers, body):
        parsed = urlsplit(target)
        path, query = parsed.path, parse_qs(parsed.query)
        if host == "calendar.atrium.invalid":
            if method != "GET" or path != "/calendar.ics":
                return self.result(404, {})
            if query.get("token") != [self.credentials["calendar"]]:
                return self.result(401, {}, credential_refused=True)
            text = (
                "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Atrium N06 Fixture//EN\r\n"
                "BEGIN:VEVENT\r\nUID:n06-linked-event\r\nDTSTART:20310701T180000Z\r\n"
                "DTEND:20310701T210000Z\r\nSUMMARY:Synthetic linked | Partiful\r\n"
                "URL:https://partiful.com/e/n06-linked\r\nEND:VEVENT\r\n"
                "BEGIN:VEVENT\r\nUID:n06-suggested-event\r\nDTSTART:20310702T190000Z\r\n"
                "SUMMARY:Synthetic suggestion | Partiful\r\n"
                "URL:https://partiful.com/e/n06-suggested\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
            )
            return self.result(
                200,
                text.encode(),
                content_type="text/calendar",
                effect="calendar-read",
                events=2,
            )
        if host == "identity.atrium.invalid":
            if method == "GET" and path in (
                "/.well-known/openid-configuration",
                "/.well-known/oauth-authorization-server",
            ):
                return self.result(
                    200,
                    {
                        "issuer": IDENTITY,
                        "authorization_endpoint": IDENTITY + "/authorize",
                        "token_endpoint": IDENTITY + "/token",
                        "jwks_uri": IDENTITY + "/jwks",
                        "userinfo_endpoint": IDENTITY + "/userinfo",
                        "response_types_supported": ["code"],
                        "subject_types_supported": ["public"],
                        "id_token_signing_alg_values_supported": ["RS256"],
                    },
                    effect="issuer-discovery",
                )
            if method == "GET" and path == "/jwks":
                return self.result(200, {"keys": [self.jwk]}, effect="issuer-jwks")
            if path.startswith("/api/"):
                if not secrets.compare_digest(
                    headers.get("X-API-KEY", ""),
                    self.credentials["pocketid-admin"],
                ):
                    return self.result(401, {}, credential_refused=True)
                if method == "GET" and path == "/api/user-groups":
                    if query.get("pagination[limit]") != ["200"]:
                        return self.result(400, {})
                    return self.result(
                        200,
                        {"data": [{"id": GROUP, "name": "n06-fixture-crew"}]},
                        effect="admin-group-read",
                    )
                if method == "POST" and path == "/api/signup-tokens":
                    try:
                        dto = json.loads(body)
                        valid = (
                            set(dto) == {"ttl", "usageLimit", "userGroupIds"}
                            and type(dto["ttl"]) is int
                            and 0 < dto["ttl"] <= 900
                            and dto["usageLimit"] == 1
                            and dto["userGroupIds"] == [GROUP]
                        )
                    except (ValueError, TypeError):
                        valid = False
                    if not valid:
                        return self.result(400, {}, body_refused=True)
                    self.signup_active = True
                    return self.result(
                        200,
                        {
                            "id": "n06-fixture-signup",
                            "token": self.credentials["signup-token"],
                            "expiresAt": datetime.fromtimestamp(
                                time.time() + dto["ttl"],
                                timezone.utc,
                            ).isoformat(),
                        },
                        effect="admin-signup-mint",
                        usage_limit=1,
                        groups=1,
                    )
                if (
                    method == "DELETE"
                    and path == "/api/signup-tokens/n06-fixture-signup"
                ):
                    if not self.signup_active:
                        return self.result(404, {})
                    self.signup_active = False
                    return self.result(204, b"", effect="admin-signup-delete")
            return self.result(404, {})
        if host == "firestore.googleapis.com":
            if not self.authorized(headers, "partiful"):
                return self.result(401, {}, credential_refused=True)
            if not path.startswith(FIRESTORE + "synthetic-event"):
                return self.result(404, {}, foreign_event_refused=True)
            if method == "GET" and path == FIRESTORE + "synthetic-event/guests":
                if query.get("pageSize") != ["300"] or query.get("pageToken", [""])[
                    0
                ] not in ("", "next-fixture-page"):
                    return self.result(400, {})
                second = "pageToken" in query
                name = "Synthetic Two" if second else "Synthetic One"
                document = {
                    "name": "projects/getpartiful/databases/(default)/documents/guests/n06",
                    "fields": {
                        "name": {"stringValue": name},
                        "status": {"stringValue": "GOING"},
                        "count": {"integerValue": "1"},
                        "user": {
                            "referenceValue": "projects/getpartiful/databases/(default)/documents/users/synthetic-partiful-user"
                        },
                    },
                }
                return self.result(
                    200,
                    {"documents": [document]}
                    | ({} if second else {"nextPageToken": "next-fixture-page"}),
                    effect="firestore-guest-page",
                    page=2 if second else 1,
                )
            if path != FIRESTORE + "synthetic-event":
                return self.result(404, {})
            if method == "GET":
                return self.result(
                    200, {"fields": self.event}, effect="firestore-event-read"
                )
            if method == "PATCH":
                try:
                    fields = json.loads(body)["fields"]
                    valid = (
                        set(fields) == {"startDate", "endDate", "timezone", "updatedBy"}
                        and query.get("updateMask.fieldPaths")
                        == ["startDate", "endDate", "timezone", "updatedBy"]
                        and query.get("currentDocument.exists") == ["true"]
                        and fields["startDate"]
                        == {"timestampValue": "2031-07-03T18:00:00.000Z"}
                        and fields["endDate"]
                        == {"timestampValue": "2031-07-03T21:00:00.000Z"}
                        and fields["timezone"] == {"stringValue": "UTC"}
                        and fields["updatedBy"]
                        == {
                            "referenceValue": "projects/getpartiful/databases/(default)/documents/users/synthetic-partiful-user"
                        }
                    )
                except (ValueError, KeyError, TypeError):
                    valid = False
                if not valid:
                    return self.result(400, {}, body_refused=True)
                self.event.update(fields)
                return self.result(
                    200,
                    {"fields": self.event},
                    effect="firestore-schedule-write",
                    update_fields=sorted(fields),
                    duration_preserved=True,
                )
            return self.result(405, {})
        if host == "api.partiful.com" and path == "/uploadPhoto":
            if (
                not self.authorized(headers, "partiful")
                or headers.get("Referer") != "https://partiful.com/"
            ):
                return self.result(401, {}, credential_refused=True)
            if method != "POST" or query.get("uploadType") != ["event_poster"]:
                return self.result(400, {}, body_refused=True)
            message = BytesParser(policy=policy.default).parsebytes(
                (
                    "Content-Type: "
                    + headers.get("Content-Type", "")
                    + "\r\nMIME-Version: 1.0\r\n\r\n"
                ).encode()
                + body
            )
            parts = list(message.iter_parts())
            if (
                len(parts) != 1
                or parts[0].get_param("name", header="content-disposition") != "file"
                or parts[0].get_content_type() != "image/png"
                or parts[0].get_payload(decode=True) != self.png
            ):
                return self.result(400, {}, body_refused=True)
            return self.result(
                200,
                {
                    "uploadData": {
                        "type": "image",
                        "fileCreatedAt": "2031-07-01T18:00:00Z",
                        "uploadedAt": "2031-07-01T18:00:00Z",
                        "path": "external/user/synthetic/n06",
                        "name": "n06",
                        "width": 2,
                        "height": 2,
                        "contentType": "image/png",
                        "storageUri": "gs://getpartiful.appspot.com/external/user/synthetic/n06",
                        "url": "https://media.atrium.invalid/uploaded/n06.png",
                        "size": len(self.png),
                    }
                },
                effect="partiful-image-upload",
                bytes=len(self.png),
                sha256=hashlib.sha256(self.png).hexdigest(),
            )
        if host == "cooklang.atrium.invalid":
            if method != "GET":
                return self.result(405, {})
            if path == "/api/recipes":
                return self.result(
                    200,
                    {
                        "name": "recipes",
                        "path": "/synthetic/recipes",
                        "children": {
                            "fixture": {
                                "name": "Fixture.cook",
                                "path": "/synthetic/recipes/Fixture.cook",
                                "recipe": {"metadata": {"id": "n06-recipe"}},
                            }
                        },
                    },
                    effect="recipe-index-read",
                )
            if path == "/api/recipes/Fixture":
                return self.result(
                    200,
                    {
                        "recipe": {
                            "ingredients": [
                                {
                                    "name": "fixture flour",
                                    "quantity": {
                                        "unit": "tbsp",
                                        "value": {
                                            "type": "number",
                                            "value": {"type": "regular", "value": 2},
                                        },
                                    },
                                }
                            ],
                            "cookware": [{"name": "fixture bowl", "quantity": None}],
                            "timers": [],
                            "sections": [
                                {
                                    "content": [
                                        {
                                            "type": "step",
                                            "value": {
                                                "items": [
                                                    {"type": "text", "value": "Mix "},
                                                    {"type": "ingredient", "index": 0},
                                                    {"type": "text", "value": " in a "},
                                                    {"type": "cookware", "index": 0},
                                                    {"type": "text", "value": "."},
                                                ]
                                            },
                                        }
                                    ]
                                }
                            ],
                        }
                    },
                    effect="recipe-document-read",
                )
            return self.result(404, {})
        if host == "mail.atrium.invalid":
            expected = (
                "Basic "
                + base64.b64encode(
                    ("api:" + self.credentials["mailgun"]).encode()
                ).decode()
            )
            if not secrets.compare_digest(headers.get("Authorization", ""), expected):
                return self.result(401, {}, credential_refused=True)
            fields = parse_qs(body.decode())
            if (
                method != "POST"
                or path != "/v3/fixture.atrium.invalid/messages"
                or set(fields) != {"from", "to", "subject", "text", "o:tracking"}
                or fields["from"] != ["N06 Fixture <sender@fixture.atrium.invalid>"]
                or fields["to"] != ["recipient@example.invalid"]
                or fields["subject"] != ["Isolated N06 fixture"]
                or fields["text"] != ["Synthetic non-delivering fixture message."]
                or fields["o:tracking"] != ["no"]
            ):
                return self.result(400, {}, body_refused=True)
            return self.result(
                200,
                {"id": "<n06-fixture-message>", "message": "Queued in fixture only"},
                effect="fixture-mail-accepted",
                actual_delivery=False,
                tracking=False,
            )
        if host == "push.atrium.invalid":
            if (
                method != "POST"
                or path != "/fixture/subscription"
                or headers.get("Content-Encoding") != "aes128gcm"
            ):
                return self.result(400, {}, body_refused=True)
            try:
                auth = headers.get("Authorization", "")
                if not auth.startswith("vapid "):
                    raise ValueError()
                pieces = dict(
                    part.strip().split("=", 1) for part in auth[6:].split(",")
                )
                if pieces["k"] != self.credentials["vapid-public"]:
                    raise ValueError()
                public = ec.EllipticCurvePublicKey.from_encoded_point(
                    ec.SECP256R1(),
                    base64.urlsafe_b64decode(pieces["k"] + "=="),
                )
                claims = jwt.decode(
                    pieces["t"],
                    public,
                    algorithms=["ES256"],
                    audience="https://push.atrium.invalid",
                    options={"require": ["aud", "exp", "sub"]},
                )
                if (
                    claims["sub"] != "mailto:fixture@example.invalid"
                    or headers.get("TTL") != "86400"
                ):
                    raise ValueError()
                key = self.receiver_key.private_numbers().private_value.to_bytes(
                    32, "big"
                )
                decoded = self.decrypt_push(body, key, self.receiver_auth)
                if decoded != {
                    "title": "N06 fixture",
                    "message": "Synthetic push only.",
                    "url": "https://whiskey.atrium.invalid/fixture",
                }:
                    raise ValueError()
            except (ValueError, KeyError, TypeError, jwt.PyJWTError):
                return self.result(400, {}, credential_or_payload_refused=True)
            return self.result(
                201,
                b"",
                effect="fixture-push-accepted",
                vapid_verified=True,
                encrypted_payload_verified=True,
                actual_delivery=False,
            )
        return None
