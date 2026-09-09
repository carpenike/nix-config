{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  product = inputs.atrium;
  controller = ../..;
  revision = "7e8355d99efd4e94cf3dade1533e647a77ee7402";
  controllerRevision = "4e5994afe48d6dbe13a0bd21fbf30bf9ff42b6ab";
  controllerRuntime = "e96bb72a530e3593414b0ae863b230eb087ac9e1";
  producerCaseCount = 161;
  catalogDigest = "686ed67e0c279a0fd6c72c915e90ad3677c5fe6b0aaef6a81ed82f28016af585";
  uidFile = "ATR-R06-N04-readback-uid-c169fb0-e96bb72.json";
  uidDigest = "6f90117a0be1c5a41defe70af66cb581637b27e52f0066d04e46345eeef37101";
  modelFile = "ATR-R06-N04-readback-models-68ec15c-95a14e9.json";
  modelDigest = "109459a871a68b10e80b2a259ac5a9af21a726ae9d8694aa9780fdc4df06cc5c";
  evidence = product + "/harness/evidence";
  catalogPath = product + "/harness/publications-suite.json";
  handoffPath = evidence + "/ATR-R06-N04-readback-publications-handoff.json";
  cleanupPath = evidence + "/ATR-R06-N04-readback-publications-cleanup.json";
  handoff = builtins.fromJSON (builtins.readFile handoffPath);
  cleanup = builtins.fromJSON (builtins.readFile cleanupPath);
  catalog = builtins.fromJSON (builtins.readFile catalogPath);
  uidPath = evidence + "/${uidFile}";
  modelPath = evidence + "/${modelFile}";
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
  receiptMatches = record: name: digest:
    record.receipt == "harness/evidence/${name}"
    && record.sha256 == digest
    && builtins.hashFile "sha256" (evidence + "/${name}") == digest;
  expectedUidAnchor = {
    receipt = uidFile;
    fingerprint = fingerprint uidPath;
    producer_sources = { inherit (uid.source) resolver controller; };
    runtime_bytes_unchanged = true;
  };
  sort = lib.sort builtins.lessThan;
  verified = product.rev == revision
    && resolverSources == catalog.source_files.resolver
    && controllerSources == catalog.source_files.controller
    && builtins.hashFile "sha256" catalogPath == catalogDigest
    && builtins.hashFile "sha256" handoffPath == "5477ae5e936994bf2832d0ba402bf43fe3bdf9261226bdae8d6493df43553633"
    && builtins.hashFile "sha256" cleanupPath == "70c175eab89e0822b817c43fa109870b3e78cdb1dc7da2a7f48cc5a8fbb0b924"
    && handoff.status == "refreshed-source-bound-publication-and-native-model-proof-passed"
    && handoff.accepted_controller_runtime_merge == controllerRuntime
    && handoff.catalog.sha256 == catalogDigest
    && handoff.catalog.exact_cases == producerCaseCount
    && receiptMatches handoff.uid_proof uidFile uidDigest
    && receiptMatches handoff.native_model_proof modelFile modelDigest
    && builtins.length catalog.expected_cases == producerCaseCount
    && builtins.length catalog.selectors == 6
    && uid.status == "passed" && uid.source_unchanged && uid.foreign_resources_unchanged
    && uid.cleanup.status == "passed" && uid.cleanup.remaining_owned_resources == [ ]
    && uid.producer_suite.contract == fingerprint catalogPath
    && uid.producer_suite.selection == catalog.selectors
    && uid.pytest.collection_failures == [ ] && uid.pytest.deselected == [ ]
    && uid.pytest.exit_code == 0 && uid.pytest.counts.passed == producerCaseCount
    && lib.all (name: lib.elem name [ "passed" "warnings" ]) (builtins.attrNames uid.pytest.counts)
    && uid.pytest.runtime.packages.pytest == catalog.collection.pytest_version
    && sort uid.pytest.collected == catalog.expected_cases
    && builtins.length (lib.unique uid.pytest.collected) == producerCaseCount
    && sort (map (row: row.id) uid.pytest.cases) == catalog.expected_cases
    && lib.all (row: row.stage == "call" && row.status == "passed") uid.pytest.cases
    && model.status == "passed" && model.source_unchanged && model.foreign_resources_unchanged
    && model.cleanup.status == "passed" && model.cleanup.remaining_owned_resources == [ ]
    && model.native_publications.status == "passed"
    && model.split_uid_runtime_anchor == expectedUidAnchor
    && model.scope.workers == 1 && !model.scope.output_cache && !model.scope.admission_hook
    && !model.full_gate
    && builtins.length model.cases == 9
    && lib.all (row: row.status == "passed") model.cases
    && cleanup.status == "independent-cleanup-passed"
    && cleanup.four_class_inventory_captured_before_either_lane
    && cleanup.independent_after_uid_inventory_equals_baseline
    && cleanup.independent_after_models_inventory_equals_baseline
    && cleanup.both_receipts_foreign_container_before_after_equal
    && cleanup.both_receipts_source_unchanged
    && cleanup.ambit_db_unchanged
    && !cleanup.images_or_shared_resources_pruned;
in
assert lib.assertMsg verified "N03 requires exact accepted publisher source bytes and complete committed proof anchors.";
{
  inherit verified controllerRuntime producerCaseCount;
  atrium = revision;
  controller = controllerRevision;
  catalog = fingerprint catalogPath;
  uidReceipt = fingerprint uidPath;
  modelReceipt = fingerprint modelPath;
  handoff = fingerprint handoffPath;
  cleanup = fingerprint cleanupPath;
  sourceFiles = { resolver = resolverSources; controller = controllerSources; };
  runtimePreflight = "Actual publication validate_collection/validate_current_sources and complete loaded-artifact verification remain mandatory.";
}
