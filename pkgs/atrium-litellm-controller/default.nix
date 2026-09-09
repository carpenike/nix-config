{ lib, python3Packages }:
python3Packages.buildPythonApplication {
  pname = "atrium-litellm-controller";
  version = "0.1.0";
  pyproject = true;
  src = lib.cleanSource ./.;
  build-system = [ python3Packages.hatchling ];
  nativeCheckInputs = [ python3Packages.pytestCheckHook ];
  pytestFlagsArray = [
    "--rootdir=."
    "-p"
    "no:cacheprovider"
    ../../tests/atrium_n04/test_credential_readback.py
  ];
  pythonImportsCheck = [ "atrium_litellm.controller" "atrium_litellm.rotation" "atrium_litellm.files" ];
  meta = {
    description = "Isolated Atrium owned LiteLLM reconciliation and acknowledged key rotation";
    mainProgram = "atrium-litellm-controller";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
