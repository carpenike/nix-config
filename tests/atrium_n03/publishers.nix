{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  product = inputs.atrium;
  controller = ../..;
  revision = "7e63e81ff8118c8a34799e20e51a8783d31a5a3e";
  controllerRevision = "ca0c0de92c2a70eae412706ccf3f68f3bcdc9b0b";
  evidence = product + "/harness/evidence";
  catalogPath = product + "/harness/publications-suite.json";
  handoffPath = evidence + "/ATR-R06-N04-corrected-publications-handoff.json";
  handoff = builtins.fromJSON (builtins.readFile handoffPath);
  catalog = builtins.fromJSON (builtins.readFile catalogPath);
  uidPath = evidence + "/ATR-R06-N04-corrected-uid-bee4189-849cf6b.json";
  modelPath = evidence + "/ATR-R06-N04-corrected-models-4b5a09e-849cf6b.json";
  uid = builtins.fromJSON (builtins.readFile uidPath);
  model = builtins.fromJSON (builtins.readFile modelPath);
  fingerprint = path: { algorithm = "sha256"; digest = builtins.hashFile "sha256" path; };
  files = root: prefix:
    let
      path = root + "/${prefix}";
      entries = builtins.readDir path;
    in
    lib.concatMap
      (name:
        let relative = "${prefix}/${name}"; in
        if name == "results" then [ ]
        else if entries.${name} == "directory" then files root relative
        else if entries.${name} == "regular" then [ relative ]
        else throw "N03 accepted publisher sources cannot contain symlinks or special files.")
      (builtins.attrNames entries);
  sourceMap = root: directories: singleFiles:
    lib.genAttrs (lib.concatMap (files root) directories ++ singleFiles)
      (name: fingerprint (root + "/${name}"));
  resolverSources = sourceMap product [
    "resolver/src"
    "resolver/tests"
    "resolver/fixtures"
    "profiles/src"
  ] [ "harness/publications_native.py" "harness/publications_suite.py" ];
  controllerSources = sourceMap controller [
    "pkgs/atrium-litellm-controller"
    "pkgs/atrium-litellm-admission"
    "tests/atrium_n04"
  ] [ ];
  receiptMatches = record:
    builtins.hashFile "sha256" (evidence + "/${record.file}") == record.sha256;
  sort = lib.sort builtins.lessThan;
  verified = product.rev == revision
    && resolverSources == catalog.source_files.resolver
    && controllerSources == catalog.source_files.controller
    && handoff.status == "passed"
    && lib.all receiptMatches handoff.receipts
    && builtins.length catalog.expected_cases == 131
    && uid.status == "passed" && uid.source_unchanged && uid.foreign_resources_unchanged
    && uid.cleanup.status == "passed" && uid.cleanup.remaining_owned_resources == [ ]
    && uid.producer_suite.contract == fingerprint catalogPath
    && uid.producer_suite.selection == catalog.selectors
    && uid.pytest.collection_failures == [ ] && uid.pytest.deselected == [ ]
    && uid.pytest.exit_code == 0 && uid.pytest.counts.passed == 131
    && sort uid.pytest.collected == catalog.expected_cases
    && builtins.length (lib.unique uid.pytest.collected) == 131
    && sort (map (row: row.id) uid.pytest.cases) == catalog.expected_cases
    && lib.all (row: row.stage == "call" && row.status == "passed") uid.pytest.cases
    && model.status == "passed" && model.source_unchanged && model.foreign_resources_unchanged
    && model.cleanup.status == "passed" && model.cleanup.remaining_owned_resources == [ ]
    && model.native_publications.status == "passed"
    && builtins.length model.cases == 9
    && lib.all (row: row.status == "passed") model.cases;
in
assert lib.assertMsg verified "N03 requires exact accepted publisher source bytes and complete committed proof anchors.";
{
  inherit verified;
  atrium = revision;
  controller = controllerRevision;
  catalog = fingerprint catalogPath;
  uidReceipt = fingerprint uidPath;
  modelReceipt = fingerprint modelPath;
  handoff = fingerprint handoffPath;
  sourceFiles = { resolver = resolverSources; controller = controllerSources; };
  runtimePreflight = "Actual publication validate_collection/validate_current_sources and complete loaded-artifact verification remain mandatory.";
}
