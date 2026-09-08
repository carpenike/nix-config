import base64
import json
import secrets
from email.message import Message
from urllib.parse import urlencode

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from required_features import FIRESTORE, GROUP, IDENTITY, RESOURCE, RequiredFeatures


def headers(**values):
    result = Message()
    for key, value in values.items():
        result[key.replace("_", "-")] = value
    return result


@pytest.fixture
def fixtures():
    credentials = {
        name: secrets.token_urlsafe(32)
        for name in (
            "calendar",
            "pocketid-admin",
            "signup-token",
            "mailgun",
            "vapid-public",
        )
    }
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    token = secrets.token_urlsafe(32)
    result = RequiredFeatures(
        credentials, key, token, b"synthetic-image-input", lambda *_: None
    )
    return result, credentials, key, token


def test_external_identity_uses_real_signed_tokens_and_public_keys(fixtures):
    fixture, _, key, _ = fixtures
    token = fixture.private_bootstrap()["external_tokens"]["valid"]
    claims = jwt.decode(
        token,
        key.public_key(),
        algorithms=["RS256"],
        audience=RESOURCE,
        issuer=IDENTITY,
    )
    assert claims["scope"] == "n06-read"
    assert jwt.get_unverified_header(token)["typ"] == "at+jwt"
    assert set(
        fixture.handle("identity.atrium.invalid", "GET", "/jwks", headers(), b"")[
            "body"
        ]
    ) == {"keys"}
    assert (
        fixture.handle("identity.atrium.invalid", "GET", "/unknown", headers(), b"")[
            "status"
        ]
        == 404
    )


def test_calendar_capability_is_required_and_never_part_of_observation(fixtures):
    fixture, credentials, _, _ = fixtures
    denied = fixture.handle(
        "calendar.atrium.invalid",
        "GET",
        "/calendar.ics?token=incorrect",
        headers(),
        b"",
    )
    assert denied["status"] == 401 and denied["effect"] is None
    accepted = fixture.handle(
        "calendar.atrium.invalid",
        "GET",
        "/calendar.ics?" + urlencode({"token": credentials["calendar"]}),
        headers(),
        b"",
    )
    assert accepted["status"] == 200 and accepted["effect"] == "calendar-read"
    assert accepted["body"].count(b"BEGIN:VEVENT") == 2
    if credentials["calendar"] in json.dumps(accepted["observed"]):
        pytest.fail("Calendar credential escaped into fixture observation")


def test_pocketid_requires_its_native_header_and_exact_single_use_group_body(fixtures):
    fixture, credentials, _, _ = fixtures
    body = json.dumps({"ttl": 300, "usageLimit": 1, "userGroupIds": [GROUP]}).encode()
    wrong = fixture.handle(
        "identity.atrium.invalid",
        "POST",
        "/api/signup-tokens",
        headers(Authorization="Bearer " + credentials["pocketid-admin"]),
        body,
    )
    assert wrong["status"] == 401 and not fixture.signup_active
    auth = headers(X_API_KEY=credentials["pocketid-admin"])
    wider = fixture.handle(
        "identity.atrium.invalid",
        "POST",
        "/api/signup-tokens",
        auth,
        json.dumps({"ttl": 300, "usageLimit": 2, "userGroupIds": [GROUP]}).encode(),
    )
    assert wider["status"] == 400 and not fixture.signup_active
    accepted = fixture.handle(
        "identity.atrium.invalid", "POST", "/api/signup-tokens", auth, body
    )
    assert accepted["status"] == 200 and fixture.signup_active
    assert (
        fixture.handle(
            "identity.atrium.invalid",
            "DELETE",
            "/api/signup-tokens/n06-fixture-signup",
            auth,
            b"",
        )["status"]
        == 204
    )
    assert (
        fixture.handle(
            "identity.atrium.invalid",
            "DELETE",
            "/api/signup-tokens/n06-fixture-signup",
            auth,
            b"",
        )["status"]
        == 404
    )


def test_firestore_requires_valid_credential_and_explicit_event_scope(fixtures):
    fixture, _, _, token = fixtures
    bad = fixture.handle(
        "firestore.googleapis.com",
        "GET",
        FIRESTORE + "synthetic-event",
        headers(Authorization="Bearer invalid"),
        b"",
    )
    assert bad["status"] == 401 and bad["effect"] is None
    foreign = fixture.handle(
        "firestore.googleapis.com",
        "GET",
        FIRESTORE + "foreign-event",
        headers(Authorization="Bearer " + token),
        b"",
    )
    assert foreign["status"] == 404 and foreign["effect"] is None
    first = fixture.handle(
        "firestore.googleapis.com",
        "GET",
        FIRESTORE + "synthetic-event/guests?pageSize=300",
        headers(Authorization="Bearer " + token),
        b"",
    )
    assert (
        first["status"] == 200 and first["body"]["nextPageToken"] == "next-fixture-page"
    )


def test_firestore_write_mask_cannot_expand_or_change_duration(fixtures):
    fixture, _, _, token = fixtures
    target = (
        FIRESTORE
        + "synthetic-event?"
        + urlencode(
            [
                ("updateMask.fieldPaths", field)
                for field in ("startDate", "endDate", "timezone", "updatedBy")
            ]
            + [("currentDocument.exists", "true")]
        )
    )
    fields = {
        "startDate": {"timestampValue": "2031-07-03T18:00:00.000Z"},
        "endDate": {"timestampValue": "2031-07-03T21:00:00.000Z"},
        "timezone": {"stringValue": "UTC"},
        "updatedBy": {
            "referenceValue": "projects/getpartiful/databases/(default)/documents/users/synthetic-partiful-user"
        },
    }
    auth = headers(Authorization="Bearer " + token)
    before = dict(fixture.event)
    refused = fixture.handle(
        "firestore.googleapis.com",
        "PATCH",
        target,
        auth,
        json.dumps(
            {"fields": fields | {"visibility": {"stringValue": "public"}}}
        ).encode(),
    )
    assert refused["status"] == 400 and fixture.event == before
    accepted = fixture.handle(
        "firestore.googleapis.com",
        "PATCH",
        target,
        auth,
        json.dumps({"fields": fields}).encode(),
    )
    assert (
        accepted["status"] == 200 and accepted["effect"] == "firestore-schedule-write"
    )
    assert fixture.event["name"] == before["name"]


def test_upload_rejects_nonmultipart_and_wrong_upload_scope(fixtures):
    fixture, _, _, token = fixtures
    auth = headers(Authorization="Bearer " + token, Referer="https://partiful.com/")
    for path in (
        "/uploadPhoto?uploadType=event_poster",
        "/uploadPhoto?uploadType=unclassified",
    ):
        refused = fixture.handle(
            "api.partiful.com", "POST", path, auth, b"not-multipart"
        )
        assert refused["status"] == 400 and refused["effect"] is None


def test_mail_never_accepts_foreign_recipient_or_tracking(fixtures):
    fixture, credentials, _, _ = fixtures
    auth = headers(
        Authorization="Basic "
        + base64.b64encode(("api:" + credentials["mailgun"]).encode()).decode()
    )
    values = {
        "from": "N06 Fixture <sender@fixture.atrium.invalid>",
        "to": "recipient@example.invalid",
        "subject": "Isolated N06 fixture",
        "text": "Synthetic non-delivering fixture message.",
        "o:tracking": "no",
    }
    for updates in ({"to": "outside@not-fixture.test"}, {"o:tracking": "yes"}):
        response = fixture.handle(
            "mail.atrium.invalid",
            "POST",
            "/v3/fixture.atrium.invalid/messages",
            auth,
            urlencode(values | updates).encode(),
        )
        assert response["status"] == 400 and response["effect"] is None
    response = fixture.handle(
        "mail.atrium.invalid",
        "POST",
        "/v3/fixture.atrium.invalid/messages",
        auth,
        urlencode(values).encode(),
    )
    assert (
        response["status"] == 200 and response["observed"]["actual_delivery"] is False
    )


def test_unclassified_push_never_becomes_an_accepted_delivery(fixtures):
    fixture, _, _, _ = fixtures
    refused = fixture.handle(
        "push.atrium.invalid",
        "POST",
        "/fixture/subscription",
        headers(Content_Encoding="aes128gcm"),
        b"invalid",
    )
    assert refused["status"] == 400 and refused["effect"] is None
