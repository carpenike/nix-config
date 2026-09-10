{ pkgs, package, lifetimeSeconds }:
let
  python = pkgs.python313.withPackages (ps: [
    (ps.toPythonModule package)
  ]);
in
pkgs.runCommand "homelab-mcp-deployment-settings"
{
  nativeBuildInputs = [ python ];
  PYTHONDONTWRITEBYTECODE = "1";
}
  ''
    python - <<'PY' > "$out"
    import json
    import secrets
    from pydantic import ValidationError
    from homelab_mcp.config import Settings

    arguments = {
        "_env_file": None,
        "public_base_url": "https://mcp.atrium.invalid",
        "pocketid_issuer": "https://identity.atrium.invalid",
        "pocketid_client_id": "deployment-fixture",
        "pocketid_client_secret": secrets.token_urlsafe(32),
    }
    lifetime = ${builtins.toJSON lifetimeSeconds}
    try:
        settings = Settings(**arguments, oauth_access_token_lifetime_seconds=lifetime)
    except ValidationError as error:
        failures = [
            {"field": list(item["loc"]), "type": item["type"]}
            for item in error.errors(include_input=False, include_context=False)
        ]
        print(json.dumps({"status": "failed", "errors": failures}))
        raise SystemExit(1) from None

    assert settings.oauth_access_token_lifetime_seconds == lifetime == 900
    assert settings.oauth_required
    assert settings.atrium_native is None
    assert settings.atrium_issuance is None
    assert settings.atrium_deny is None
    assert settings.atrium_policy is None

    try:
        Settings(**arguments, oauth_access_token_lifetime_seconds=4 * 60 * 60)
    except ValidationError as error:
        assert any(
            item["loc"] == ("oauth_access_token_lifetime_seconds",)
            and item["type"] == "less_than_equal"
            for item in error.errors(include_input=False, include_context=False)
        )
    else:
        raise AssertionError("the incompatible four-hour configuration was accepted")

    print(json.dumps({
        "status": "passed",
        "configured_access_token_seconds": lifetime,
        "previous_four_hour_configuration_rejected": True,
        "atrium_native_adoption_enabled": False,
        "native_services_started": False,
    }))
    PY
  ''
