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

`full_n06` remains incomplete: the bounded helper/transport proof does not
complete deployment/adoption or the assembled phase-1 gates. A passing bounded
matrix must not be promoted into hostname isolation, image-only enforcement,
full household integration, or a production cutover claim.

The [clean final receipt](results/n06-egress-17de47c2.json) records 14 passing
bounded cases, including authenticated provider account/model observations and
per-denial kernel counter increments. The earlier
[clean functional receipt](results/n06-egress-fec78464.json) is retained; its
inherited N07 scope labels were corrected in the final runner. The
[bootstrap diagnostic](results/n06-egress-bootstrap-diagnostic.json) is a failed
startup attempt, not acceptance evidence.

The [capability-composition follow-up](results/n06-egress-66d72010.json) records
15 native cases and 16 Nix checks at clean source `66d72010`. All five Linux
capability sets are zero, the actual consumer cannot remove the nftables table,
and the existing permit/deny matrix still passes. Earlier receipts are retained;
this does not promote the remaining full N06 gates.

## Required non-model permit extension

The bounded extension uses immutable accepted Whiskey
`273cf414cac75276492ee849bb3ea257ce47f8de` and adds actual calendar reconciliation,
Firestore pagination/schedule updates, multipart poster upload, external JWT
verification, Pocket ID signup-token mint/delete, recipe parsing, Mailgun and
encrypted Web Push helper paths. No Whiskey source or fetch/auth implementation
is replaced. `required_features.py` implements finite, non-delivering fixture
provider contracts; `push_wire.mjs` uses the locked native sender's `http_ece`
dependency to verify decrypted content.

`source_artifact.py` checks the entire fixed Git archive. The existing build
runner materializes only that source (never `.env`) and fingerprints source,
compiled members, dependency members and archive. The native runner verifies
the artifact before execution. Restore its locked dependencies only after the
missing-compiler failure, then rebuild through the existing TypeScript tool:

```sh
python tests/atrium_n06/build_runtime.py --whiskey /path/to/immutable-object-containing-repository \
  --output .artifacts/n06-whiskey-runtime
# If the owned artifact source has no compiler:
(cd .artifacts/whiskey-source && npm ci --ignore-scripts --no-audit --no-fund)
```

The shared fixture lease must be explicitly released by its current owner and
atomically claimed before any native/container/kernel run. No polling, prune,
global networking or stopping another fixture is permitted. Source/artifact
preparation can run independently:

```sh
python tests/atrium_n06/native_runner.py --prepare-only \
  --harness /path/to/atrium-git-objects \
  --whiskey /path/to/whiskey-git-objects --spec /path/to/current-owner-spec.md \
  --evidence tests/atrium_n06/results/n06-required-prepare-NEW.json
```

Preparation exits before generating credentials or creating containers.
`prepared` and Nix/fixture-unit success are not kernel/native evidence. Remove
`--prepare-only` only after the source commit and coordinated lease acquisition.
The ordinary native run retains every old text/image/reference and direct
Anthropic/backend refusal case, using the same UID11001, empty capability sets,
NoNewPrivileges and address/port policy.

Feature evidence distinguishes actual helper/wire/fixture effects from browser
workflows or production authorization. Calendar denial may persist a native
sync-error record but must not change operation schedule fields. Firestore
updates are limited to their real four-field mask and preserve duration.
Pocket ID tokens, native JWTs, VAPID/private receiver keys and subscription auth
remain memory/private-runtime-only. No fixture delivers email/push/upload to a
real recipient or creates a new user authority. Cache/warm recipe reads may
produce one or two native document fetches; the observed count is recorded,
not replaced with a fake single count.

Full N06/T16/N03/N07 promotion and production dynamic-origin selection remain
separate. Earlier native receipts are historical proof of their exact source;
the required-feature proof below has its own clean source pin.

The [first required-feature native receipt](results/n06-required-native-80cffd3f.json)
binds 23 passing groups (15 retained controls and eight new feature groups) to
clean source `80cffd3f6838ce7acf28ab5ff85a98103d2f8df4`. Push stopped before any
outbound request with `SQLITE_CONSTRAINT_FOREIGNKEY`: the fixture had omitted
the synthetic owner required by the native subscription schema. Fixture setup
now provisions that crew row with the existing `upsertUserOnLogin` helper,
without changing the schema, auth, transport or egress policy. The failed
diagnostic remains intact and is not counted as a passing push case.
All seven exact invocation containers and its network were rechecked absent;
the pre-existing `ambit-db` remained running unchanged.

### Completed bounded native cohort

The [corrected native receipt](results/n06-required-native-b47ce525.json) binds
**24 passing groups** to clean source
`b47ce5258da163189350a8891e0ba3ba117c2b57`: all 15 retained controls plus all nine
required-feature permit/deny/recovery groups. There are 18 explicit feature
denial cases with zero prohibited fixture effects and nine successful
recoveries. The [handoff](results/n06-required-native-b47ce525-handoff.json)
records exact commands, component pins, diagnostics and cleanup.

All helper calls run in the same native PID 8 / UID 11001 with all five
capability sets zero and `NoNewPrivileges=1`. Direct Anthropic and direct native
backend denials each increment the kernel reject counter; all previous real
text/image/reference permits remain successful. No policy, source adapter or
authentication override was needed.

Push now reaches the actual encrypted transport: the fixture verifies ES256
VAPID and decrypts the AES128GCM payload, rejects the wrong subscription auth
with HTTP 400 and zero accepted delivery, then accepts recovery with HTTP 201.
Native foreign-owner deletion remains refused. The synthetic crew-row setup
is not an OIDC/login or new-user-authority proof.

All 14 exact containers and two networks from both attempts were rechecked
absent; the complete foreign container inventory remained equal, with
`ambit-db` running unchanged. Only N06's lease row was deleted, and the lease
query was empty. No further VM use is needed for this delivery.

These are actual helper/wire capabilities, not full browser login, invitation
or push-permission workflows. N03 ingress assembly, N05 admission, broader
cross-adapter gates and production selection of dynamic destinations remain
separate; none is silently promoted by this receipt.
