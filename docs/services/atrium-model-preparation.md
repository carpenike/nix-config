# ATR-N03 — source-only model assembly preparation

This is a **disabled, unimported isolated host definition**, stacked on foundation
`60faba29f84bc4a0c1a226828c7a0217a3760bb7`. No new model permit, kernel/UID
proof, native fixture, production activation or completed T-case is claimed.
The accepted [C8/JTI handoff](../../tests/atrium_n03/results/n03-c8-native-6fac02ef-handoff.json)
and all older receipts remain historical and unchanged.

Preparation source `7c89709e438beaba6fd485075138c50c7b2daa50` has a
[clean source-only receipt](../../tests/atrium_n03/results/n03-model-preparation-7c89709e.json):
60 Nix assertions, two Caddy adaptations and six configuration tests pass.
The receipt retains both explicit producer-field compatibility blockers and
all seven unexecuted native groups; it verifies all 22 baseline receipts
unchanged. It is not a native model or cross-UID execution receipt.

`modelPlaneReady` is false, `models.acceptedPublisherPins` is null, the gateway,
controller/timer, admission activation and input-copy unit are disabled, and
the public model origin still returns 503. A Nix assertion prevents accidental
activation. Changing that boundary requires later source review and explicit
authorization; this preparation does not reserve or query a fixture lease.

## Prepared files and contracts

* [`models.nix`](../../tests/atrium_n03/models.nix): non-secret source of truth
  for roles, directories, live reader paths, native issuer, controller/admission
  settings, pinned-image arguments and the bootstrap sequence.
* [`model-host.nix`](../../tests/atrium_n03/model-host.nix): disabled NixOS
  configuration using the actual R06 export, N04 CLI and N05 package.
* [`model-evaluate.nix`](../../tests/atrium_n03/model-evaluate.nix) and
  [`test_models.py`](../../tests/atrium_n03/test_models.py): source-only checks.
* [`model-cases.json`](../../tests/atrium_n03/model-cases.json): seven unexecuted
  topology groups, permit/deny counterparts and existing helper references.
* [`model_cases.py`](../../tests/atrium_n03/model_cases.py): two small real-HTTP
  pairs requiring actual R03/R06 delivery, an intended-account provider observer,
  the existing external client and real R07 administration.
* [`model_probe.py`](../../tests/atrium_n03/model_probe.py): a later gateway-UID
  reader/custody probe using actual N05/R06 protected readers. It distinguishes
  permission refusal from an unmounted path and requires an owner-side existence
  counterpart; missing setup cannot masquerade as a permission proof.

The interface follows Atrium's `harness/PUBLICATIONS.md` and the
[N04 controller contracts](atrium-litellm-controller.md), not a new permission
engine or publication format. Producers alone create/replace their snapshots.
There is no root relay, ACL repair, shared signer identity, copied authorization
implementation, or fabricated ownership document.

## Declared identities and custody — not yet runtime-observed

All IDs are centralized **fixture reservations**, not production values.

| Role | UID / primary GID | Additional access |
| --- | --- | --- |
| Resolver | `65432` | Metadata group `65439` |
| Controller | `65430` | Metadata `65439`; separate delivery/ack group `65431` |
| Gateway | `65437` | Metadata `65439` only |
| Whiskey | `65431` | Existing delivery/ack group; no metadata membership |

Two distinct publisher-owned `2750` directories use metadata group `65439`:

* `/run/atrium-n03-publications/resolver`
* `/run/atrium-n03-publications/controller`

The documented producer options select `0640` replacements. Readers gain
read/traverse only. Resolver state/signing and model escrow, controller inventory
and provider input, and gateway admission history retain separate `0700` private
directories and `0600` private-file contracts.

Service tokens use controller-owned `/run/atrium-n03/delivery` (`2750`, separate
group `65431`) and `0640` files. Acknowledgements use Whiskey-owned
`/run/atrium-n03/acknowledgements/whiskey` (`0750`, group `65431`), not the
publication group. Metadata membership reveals no service or management key.

N05's current policy/settings and public CA are copied from non-secret N02/configuration
outputs into regular root-owned runtime files, group `65439`, mode `0640`, under
a `0750` input directory. This is **static configuration delivery**, not a relay
of live producer snapshots. The real reader rejects Nix-store paths, symlinks and
world-readable files; type validation alone does not prove this boundary.

## Actual service/configuration path

R06 retains the exact registry model origin
`https://litellm.atrium.invalid:18443` as issuer/endpoint. Its documented
`Settings.litellm.publication_directory` and `publication_reader_gid` name only
the resolver export. N04 reads `associations.json` with publisher UID `65432`;
R06 reads the controller's live `native-bindings.json` with UID `65430`.

N04's existing separate transport endpoint is `http://127.0.0.1:14000`; its
issuer remains the public origin. `publication_reader_gid`, `bindings_snapshot`
and `service_association_snapshot` select only the controller export. Backend
hosts, credential references and aliases come from the actual N02 model
registry and synthetic per-account fixture inputs.

The candidate Caddy route forwards to loopback and preserves native
authentication. It is adapted **only as a syntax preview**; the effective route
remains 503. Inference credentials still require native/N05 management denial;
proxy headers do not assert a trusted role.

The gateway uses N07's exact LiteLLM **1.99.1** image digest and real
`/app/docker/prod_entrypoint.sh`, loopback port `14000`, and two workers. It
registers both:

```text
LITELLM_WORKER_STARTUP_HOOKS=atrium_admission.bootstrap:install
callbacks: [atrium_admission.hook.admission]
```

The declared gateway UID has no capabilities or privilege escalation and joins
the invocation-owned namespace. Its container launcher is setup machinery, not
the application identity. Only read-only metadata/configuration/package/CA
mounts and its own private state are declared; publisher state, signing,
provider inputs, service tokens and acknowledgements are not mounted. Native
stdout/stderr and container logging are suppressed; N05's actual private durable
alerts/history remain authoritative operational evidence.

`ATRIUM_ADMISSION_SETTINGS` points to regular runtime settings. N05 reads R06's
rich `admission-associations.json` and N04's service snapshot as independent,
complete producers with exact publisher UIDs. It uses the actual R07
issuer/feed/JWKS, 20-second polling and a five-second fetch bound. Per-service
CA references do not change host or VM trust.

W03 retains its actual live key path, issuer/template/model and owner UID.
Neither an environment value nor `LoadCredential` snapshots its rotating token.
The isolated template reuses N04/N06's bounded timings: 600-second lifetime,
two-second rotation and five-second acknowledged overlap. These are fixture
settings, not new production policy or evidence that rotation ran.

## Exact blockers before native execution

Pins remain Atrium `5f919f085ca0e77664b72d13e96ceeb0680688e4`,
MCP `338cbbdb990a5751d199f276c5d65b07730cd97d`, and Whiskey
`273cf414cac75276492ee849bb3ea257ce47f8de`. No unreviewed publisher branch was
merged, cherry-picked, copied or vendored.

1. That accepted Atrium `LiteLLMSettings` rejects `publication_directory` and
   `publication_reader_gid` as extra fields.
2. This foundation's actual N04 CLI rejects `publication_reader_gid`.
   Source tests assert those **blocked compatibility results**; they do not
   strip fields or call a substitute controller.
3. Parent must supply accepted exact publisher commits after the corrected
   complete-collection Linux/UID and model anchor is accepted. Earlier receipts
   or selected subsets cannot substitute for it.
4. A later reviewed native assignment must compose the existing N07
   database/provider/resource lifecycle with this host, explicit real
   R01/R06/N04/N05 initialization, authenticated readiness and the prepared
   pairs. Existing immutable image/wheel/source/compiled guards stay mandatory.
   The native runner is not automatically extended or authorized by these
   preparation helpers.

The seven groups cover public model/target/backend refusal, actual R07 denial,
missing ownership, cross-UID atomic replacements/private custody, W03
replacement/acknowledgement, overlap/retirement and bounded freshness rules.
**All seven are unexecuted.** Full protocol/stream/worker/cache/browser/N06/N07
coverage and production/model adoption remain outside this tranche.

## Source-only validation

The existing foundation CI job runs these checks with builders disabled:

```sh
nix build --builders '' --no-write-lock-file --no-link \
  .#checks.aarch64-darwin.atrium-n03-units \
  .#checks.aarch64-darwin.atrium-n03-caddy \
  .#checks.aarch64-darwin.atrium-n03-model-preparation \
  .#checks.aarch64-darwin.atrium-n03-model-caddy-preview \
  .#checks.aarch64-darwin.atrium-n03-model-python
```

CI uses corresponding `x86_64-linux` checks. These evaluate the preserved native
invariants, candidate wiring and Caddy syntax, and run six configuration tests
using the existing Python environment. Two tests assert unsupported producer
fields; their success is not producer compatibility. No selected test initializes
credentials/state, starts a native fixture, queries a lease, or executes a
gateway probe/HTTP helper past its disabled gate.
