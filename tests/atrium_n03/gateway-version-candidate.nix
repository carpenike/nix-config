{ inputs, candidateRuntime, candidateNative, versionCandidate, scopeState ? "live" }:
let
  inherit (inputs.nixpkgs) lib;
  base = import ./production-envelope.nix {
    inherit inputs candidateRuntime candidateNative scopeState;
  };
  nativeVersion = versionCandidate.native_version;
  generated = candidateRuntime.lib.renderForGateway {
    registry = base.registry;
    inherit nativeVersion;
  };
  models = lib.recursiveUpdate base.models {
    resolver.native_version = nativeVersion;
    admission.native_version = nativeVersion;
  };
in
assert versionCandidate.kind == "atrium.litellm-version-candidate";
assert versionCandidate.version == "1.100.1";
assert nativeVersion == "v1.100.1";
assert versionCandidate.image == "ghcr.io/berriai/litellm@sha256:a3715fa7ad8387941ab697259bd2881d68931657247a41984f90fae6d11c62bf";
base // {
  inherit generated models;
  resolver = base.resolver // { litellm = models.resolver; };
  versions = base.versions // { litellm = versionCandidate.image; };
  qualification = base.qualification // {
    native_version = nativeVersion;
    mutable_mismatch_policy = (candidateRuntime.lib.renderForGateway {
      registry = base.registry // { environment = "isolated"; };
      inherit nativeVersion;
    }).resolver;
    accepted_gateway_pin_modified = false;
  };
}
