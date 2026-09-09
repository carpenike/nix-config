# Isolated Atrium admission deployment

This repository consumes
`inputs.atrium.packages.${system}.atrium-litellm-admission` and
`inputs.atrium.nixosModules.litellm-admission`. The app owns Python packaging,
admission behavior, callback integration and version-compatibility tests.
The consumer does not add source directories to `PYTHONPATH` or run a duplicate
product pytest suite.

An explicitly isolated deployment can select the package and runtime path:

```nix
{ inputs, pkgs, ... }:
{
  imports = [ inputs.atrium.nixosModules.litellm-admission ];
  services.atriumLitellmAdmission = {
    enable = true;
    isolatedHarness = true;
    package = inputs.atrium.packages.${pkgs.stdenv.hostPlatform.system}.atrium-litellm-admission;
    settingsFile = "/run/atrium-n05-fixture/settings.json";
  };
}
```

The host retains settings-path selection and provisioning. The imported module
installs the selected package and exposes only the path string at
`/etc/atrium-n05-isolated-settings-path`; it does not copy runtime settings into
the store or activate a gateway. Runtime secrets and signing material remain
outside checkouts and the Nix store. Live rotating publications must not be
replaced with environment or systemd credential snapshots.

## Deployment checks

```sh
nix build --no-write-lock-file --no-link --builders '' \
  .#checks.aarch64-darwin.atrium-n05-package-smoke \
  .#checks.aarch64-darwin.atrium-n05-units
```

The smoke check consumes the exact app export and executes only its CLI
`--help`. The unit check evaluates isolated host configuration, package and
settings references, default-disabled behavior and absence of gateway/public
port activation. The existing build workflow requires these deployment checks;
ordinary host build and lint gates remain intact.

These checks are not native T-case acceptance. Use the app-owned harness for
behavior, security and native coverage under separate authorization. See
[deployment consumption](atrium-deployment.md) and its
[immutable historical source/evidence pointer](atrium-deployment.md#source-and-historical-evidence).
