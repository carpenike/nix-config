# Atrium Whiskey egress deployment

The selected Forge deployment is described in
[Direct Whiskey adoption](atrium-whiskey-cutover.md). It keeps exact declared
hostnames, resolves complete IPv4 address sets at startup and every minute,
and atomically replaces the service-UID rules. DNS failure reports an error
without widening the previous boundary. Provider exceptions remain direct
image paths, not an image-only network guarantee.

Atrium owns the generic namespace module, enforcement helper, behavior/native
tests and acceptance evidence. This repository imports
`inputs.atrium.nixosModules.whiskey-egress-fixture` and retains host-specific
values: service identity, namespace and binding paths, model configuration,
credential references and the selected network policy.

[`tests/atrium_n06/fixture.nix`](../../tests/atrium_n06/fixture.nix) generates those
synthetic deployment values from the retained Nix registry.
[`evaluate.nix`](../../tests/atrium_n06/evaluate.nix) checks consumption and module
composition, including configured namespace/path references and explicit
capability resets. `checks.<system>.atrium-n06-units` evaluates these assertions
without activating a service or claiming native egress behavior.

Actual cross-service/native acceptance is app-owned and requires separate
authorization. No local copy of its runner, helper implementation or receipt
collection remains in nix-config.

See [Atrium deployment consumption](atrium-deployment.md) for the public module
contract and [historical source/evidence](atrium-deployment.md#source-and-historical-evidence).
The earlier N03 failures and22-of-27 result remain historical, not promoted by
this ownership correction.
