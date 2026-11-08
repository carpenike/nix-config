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
    import os
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
    # homelab-mcp 0.38.0 removed the Atrium native integration: its settings
    # are gone, and a leftover native-mode variable refuses the start.
    for retired in ("atrium_native", "atrium_issuance", "atrium_deny", "atrium_policy"):
        assert retired not in Settings.model_fields, retired
    os.environ["HOMELAB_MCP_ATRIUM_NATIVE"] = "/run/credentials/native.json"
    try:
        Settings(**arguments, oauth_access_token_lifetime_seconds=lifetime)
    except ValueError as error:
        assert "Retired Atrium native-mode settings" in str(error), error
    else:
        raise AssertionError("a leftover Atrium native-mode variable was accepted")
    finally:
        del os.environ["HOMELAB_MCP_ATRIUM_NATIVE"]

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
        "retired_atrium_native_settings_refused": True,
        "native_services_started": False,
    }))
    PY
  ''
