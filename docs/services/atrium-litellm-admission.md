# Isolated Atrium LiteLLM admission packaging

ATR-N05 exports `packages.<system>.atrium-litellm-admission` and the corresponding
overlay package. It consumes the actual resolver/profile packages from the
already merged Atrium input, rather than embedding another verifier.
Python 3.12 is selected explicitly to match those Nix packages. The native
1.99.1 image has its own interpreter; the native harness separately verifies
the bytes of its four pure-Python wheel artifacts.

These changes do **not** enable a gateway, initialize authorization history,
start a poller, publish credentials, open a port, or alter production keys.
N03 owns eventual host/container integration. The module under
`tests/atrium_n05/module.nix` is deliberately not imported by a production host.

## Package and module usage

The installed command is `atrium-litellm-admission`. Its `initialize` operation
requires an explicitly supplied protected settings file and refuses existing
or partially initialized history. Merely installing the package does not run it.
See [the adapter contract](../../pkgs/atrium-litellm-admission/README.md) for
settings, producer trust, native callback registration, and failure behavior.

An explicitly isolated NixOS fixture may import the test module and configure:

```nix
{
  services.atriumLitellmAdmission = {
    enable = true;
    isolatedHarness = true;
    package = pkgs.atrium-litellm-admission;
    settingsFile = "/run/atrium-n05-fixture/settings.json";
  };
}
```

The module installs the selected package and publishes only the **path string**
at `/etc/atrium-n05-isolated-settings-path`. It does not read the settings at
evaluation time or copy their contents into the store. Relative settings paths,
store paths, and enablement without explicit isolation are rejected. The
default-disabled module is inert.

No raw credential, signing material, private runtime directory, or live
authorization database belongs in a build input. Provision runtime material
outside every checkout and the Nix store. Do not substitute systemd credential
snapshots for live rotating publications or silently initialize missing state.

## Reproducible checks

For the local Darwin worktree:

```sh
nix build --no-write-lock-file --no-link --builders '' \
  .#checks.aarch64-darwin.atrium-n05-package \
  .#checks.aarch64-darwin.atrium-n05-python \
  .#checks.aarch64-darwin.atrium-n05-units
```

The package check builds the distribution and imports its engine/producer
modules. The Python check runs the existing pytest fixtures with the actual
admission, resolver, and profile sources. Generated keys and fixture state
remain in the build's private temporary directory, not the output or source.
Tests requiring the native LiteLLM SDK are explicitly conditional and remain
part of the separate pinned-native validation, not this Nix unit-check claim.
The module check evaluates the real NixOS module with valid/invalid inputs
and confirms explicit isolation, reference-only settings, default-disabled
behavior, and absence of gateway activation or public ports.

The existing `Build Nix systems` workflow runs these three checks on Linux
for changes to admission code, its fixtures, relevant package/flake wiring,
or that workflow. The job participates in the required `Nix Build Successful`
roll-up; merely evaluating the flake cannot stand in for a package build.
Existing host build and lint gates remain intact.

These are packaging, unit, and evaluation results, **not** T-case native
acceptance. The [native lanes and their evidence](../../tests/atrium_n05/README.md)
use the pinned gateway, real authorization implementations, and isolated
permit/deny requests. Full N05 acceptance still requires their complete
route/fault/ownership coverage and review.
