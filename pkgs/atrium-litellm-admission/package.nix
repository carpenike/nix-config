{ lib, python3Packages, atriumResolver, atriumProfiles }:
python3Packages.buildPythonPackage {
  pname = "atrium-litellm-admission";
  version = "0.1.0";
  pyproject = true;
  src = lib.cleanSource ./.;
  build-system = [ python3Packages.hatchling ];
  dependencies = [
    atriumResolver
    atriumProfiles
    python3Packages.httpx
    python3Packages.pydantic
  ];
  pythonImportsCheck = [ "atrium_admission.engine" "atrium_admission.producers" ];
  meta = {
    description = "Opt-in isolated Atrium owned-key admission";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
