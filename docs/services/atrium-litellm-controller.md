# Atrium LiteLLM controller deployment

Runtime reconciliation, readback, ownership and rotation behavior now belong to
the Atrium application. This repository consumes
`inputs.atrium.packages.${system}.atrium-litellm-controller`; it does not build a
local Python implementation or run a second product test suite.

Deployment-owned files remain:

* [`litellm-controller-isolated.nix`](../../hosts/forge/atrium/litellm-controller-isolated.nix):
  isolated-host guard, package selection, users/groups, credential-path references,
  state paths and timer/service settings.
* [`tests/atrium_n04/host.nix`](../../tests/atrium_n04/host.nix),
  [`fixture.nix`](../../tests/atrium_n04/fixture.nix) and
  [`evaluate.nix`](../../tests/atrium_n04/evaluate.nix):
  host configuration values and deployment-consumption assertions.

`checks.<system>.atrium-n04-package-smoke` verifies the exported CLI's `--help`;
`atrium-n04-units` checks host wiring without activation. Neither is native
convergence or a full T-case.

See [Atrium deployment consumption](atrium-deployment.md) for the package/module
contract and [historical source/evidence](atrium-deployment.md#source-and-historical-evidence).
The isolated module must not be imported into live Forge; production adoption is
a separate owner decision.
