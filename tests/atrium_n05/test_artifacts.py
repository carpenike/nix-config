import io
import tarfile
from zipfile import ZipFile

import pytest

import supervisor


@pytest.mark.parametrize(
    "fault", [None, "changed", "missing", "additional", "external-code", "invalid"]
)
def test_native_wheels_must_match_every_actual_source_file(
    tmp_path, monkeypatch, fault
):
    content = b"FIXTURE_SOURCE = True\n"
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w") as output:
        for directory, package in (
            ("profiles", "atrium_profiles"),
            ("resolver", "atrium_resolver"),
        ):
            member = tarfile.TarInfo(f"{directory}/src/{package}/__init__.py")
            member.size = len(content)
            output.addfile(member, io.BytesIO(content))
    monkeypatch.setattr(supervisor, "git", lambda *_: archive.getvalue())
    monkeypatch.setattr(supervisor, "ROOT", tmp_path)
    for directory, package in (
        ("admission", "atrium_admission"),
        ("controller", "atrium_litellm"),
    ):
        path = tmp_path / "pkgs" / f"atrium-litellm-{directory}" / package
        path.mkdir(parents=True)
        (path / "__init__.py").write_bytes(content)
    wheels = tmp_path / ".artifacts/admission-wheels"
    wheels.mkdir(parents=True)
    packages = (
        "atrium_admission",
        "atrium_litellm",
        "atrium_profiles",
        "atrium_resolver",
    )
    for package in packages:
        path = wheels / (package + ".whl")
        if package == "atrium_admission" and fault == "invalid":
            path.write_bytes(b"not a wheel")
            continue
        with ZipFile(path, "w") as wheel:
            if package == "atrium_admission":
                if fault != "missing":
                    wheel.writestr(
                        package + "/__init__.py",
                        b"changed" if fault == "changed" else content,
                    )
                if fault == "additional":
                    wheel.writestr(package + "/unrecorded.py", content)
                if fault == "external-code":
                    wheel.writestr("sitecustomize.py", content)
            else:
                wheel.writestr(package + "/__init__.py", content)
    if fault is None:
        encoded, hashes = supervisor.verified_wheels(
            "fixture-repository", "fixture-revision"
        )
        assert len(encoded) == len(hashes) == 4
    else:
        with pytest.raises(RuntimeError, match="native_wheel|wheel_source"):
            supervisor.verified_wheels("fixture-repository", "fixture-revision")
