# ATR-N06 isolated egress fixtures

See [the enforcement contract, outbound inventory and limitations](../../docs/services/atrium-whiskey-egress.md).

This directory is not imported by Forge. `fixture.nix` renders the shared isolated
registry; `egress.py` is the actual UID-scoped namespace filter used by both the
unimported module and native fixture. `runtime.py` runs the real N04 controller and
actual compiled Whiskey helpers, with no fetch override or fake authentication.
`upstreams.py` provides non-actuating TLS responses and authenticated counters.

The native runner refuses a shared VM already running anything other than
`ambit-db`, records component/spec revisions, and removes only its exact
invocation-owned resources. All private runtime keys, certificates, databases and
acknowledgements live inside private container runtime storage, never source or
the Nix store.

`full_n06` remains incomplete while the explicitly documented non-model/owner
policy gates are outstanding. A passing bounded matrix must not be promoted into
hostname isolation, image-only enforcement, full household integration, or a
production cutover claim.
