{ pkgs, resolverPackage }:
let
  identity = import ../../hosts/forge/atrium/identity.nix { inherit (pkgs) lib; };
  python = pkgs.python312.withPackages (ps: [ (ps.toPythonModule resolverPackage) ]);
in
pkgs.runCommand "atrium-pocketid-bootstrap"
{
  nativeBuildInputs = [ python ];
  PYTHONDONTWRITEBYTECODE = "1";
}
  ''
    python - <<'PY' > "$out"
    import json
    import os
    import sqlite3
    import subprocess
    import sys
    import tempfile
    from contextlib import closing
    from pathlib import Path

    from atrium_resolver.config import Bootstrap, Settings

    enrollment = ${builtins.toJSON (builtins.toJSON identity.bootstrap)}
    configured = ${builtins.toJSON (builtins.toJSON identity.settings)}
    registry = json.loads(${builtins.toJSON (builtins.toJSON identity.registry)})
    bootstrap = Bootstrap.model_validate_json(enrollment)
    settings = Settings.model_validate_json(configured)
    assert settings.isolated_harness is False
    assert settings.signing is None and settings.policy_path is None
    assert settings.group_authority is None
    assert len(bootstrap.principals) == len(bootstrap.identities) == 1
    principal = bootstrap.principals[0]
    binding = bootstrap.identities[0]
    assert principal.id == binding.principal == "ryan"
    assert principal.kind == "human" and principal.roles == {"admin", "adult"}
    assert registry["principals"][principal.id]["bindings"] == [
        {"authority": binding.authority, "subject": binding.subject}
    ]
    assert registry["principals"][principal.id]["groups"] == []
    authority = settings.authorities[0]
    assert binding.authority == authority.id == "pocketid"
    assert registry["authorities"][authority.id]["issuer"] == authority.issuer
    assert registry["authorities"][authority.id]["audience"] == authority.audience
    assert registry["authorities"][authority.id]["jwksUri"] == authority.jwks_uri

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = json.loads(configured)
        config["state_directory"] = str(root / "state")
        (root / "settings.json").write_text(json.dumps(config))
        (root / "enrollment.json").write_text(enrollment)
        command = [
            sys.executable, "-m", "atrium_resolver.cli", "--config",
            str(root / "settings.json"), "bootstrap", "--enrollment",
            str(root / "enrollment.json"),
        ]
        first = subprocess.run(command, capture_output=True, check=False, timeout=30)
        assert first.returncode == 0, "actual resolver bootstrap refused valid mapped identity"
        database = root / "state/resolver.sqlite3"
        with closing(sqlite3.connect(database)) as connection:
            assert connection.execute(
                "SELECT authority_id, subject, principal_id FROM identities"
            ).fetchall() == [(binding.authority, binding.subject, principal.id)]
            assert connection.execute(
                "SELECT role FROM principal_roles WHERE principal_id=? ORDER BY role",
                (principal.id,),
            ).fetchall() == [("admin",), ("adult",)]
            assert connection.execute("SELECT count(*) FROM group_memberships").fetchone() == (0,)
            before = list(connection.iterdump())
        repeated = subprocess.run(command, capture_output=True, check=False, timeout=30)
        assert repeated.returncode == 2, "existing identity state was overwritten"
        with closing(sqlite3.connect(database)) as connection:
            assert list(connection.iterdump()) == before
        invalid = json.loads(enrollment)
        invalid["identities"][0]["authority"] = "unregistered"
        config["state_directory"] = str(root / "foreign-state")
        (root / "settings.json").write_text(json.dumps(config))
        (root / "enrollment.json").write_text(json.dumps(invalid))
        foreign = subprocess.run(command, capture_output=True, check=False, timeout=30)
        assert foreign.returncode == 2, "unregistered authority was accepted"
        with closing(sqlite3.connect(root / "foreign-state/resolver.sqlite3")) as connection:
            assert connection.execute("SELECT count(*) FROM identities").fetchone() == (0,)
            assert connection.execute("SELECT count(*) FROM principals").fetchone() == (0,)
        assert oct(os.stat(database).st_mode & 0o777) == "0o600"
    print(json.dumps({
        "status": "passed", "actual_bootstrap_permitted": True,
        "repeat_bootstrap_refused": True, "foreign_authority_refused": True,
        "registry_binding_matches": True, "live_resolver_initialized": False,
        "pocketid_mutated": False, "group_membership_seeded": False,
    }))
    PY
  ''
