# pgBackRest Repository Encryption Migration

## Status

This migration is designed but not activated. Forge continues to use the
existing unencrypted repositories:

- repo1: `/mnt/nas-postgresql/pgbackrest`
- repo2: `/forge-pgbackrest` in the production R2 bucket

Do not add cipher options to either existing namespace. pgBackRest does not
convert stored backup history in place. A cipher passphrase is required to read
an encrypted repository, and changing or losing it makes that history
unrecoverable.

The implementation is blocked until the operator completes the choices and
SOPS steps below. Passphrases must be created and entered directly in a trusted
terminal. Do not send them through chat, issue comments, command arguments, or
unencrypted files.

## Safety Invariants

1. Existing repository paths are never reused for encrypted data.
2. Existing backup history is never rewritten, expired, or deleted during
   migration.
3. Every WAL segment reaches both repository generations during the bridge
   phase.
4. The encrypted repositories must each pass a physical restore drill before
   cutover.
5. A deployment may select only a declared migration phase. Missing secrets or
   incomplete repository evidence must fail closed.
6. Legacy namespaces remain available for at least 30 days after cutover and
   until two later encrypted restore drills pass.

## Operator Decisions

Record these decisions before implementing the bridge:

| Decision | Recommended default |
| --- | --- |
| NFS namespace | `/mnt/nas-postgresql/pgbackrest-v2` |
| R2 namespace | `/forge-pgbackrest-v2` |
| Cipher | `aes-256-cbc`, the pgBackRest-supported encrypted mode |
| Passphrases | Independent random passphrases for NFS and R2 |
| Cutover | Both encrypted repositories in one maintenance window |
| Legacy retention | At least 30 days and two successful later drills |
| Recovery kit | Store both passphrases outside Forge in the DR kit |

Independent passphrases preserve failure-domain separation. A shared
passphrase is operationally simpler, but compromise or loss then affects both
copies at once.

## Secret Gate

Add the selected values directly to
`hosts/forge/secrets.sops.yaml` with `sops`. Use stable SOPS keys such as:

```yaml
pgbackrest:
  nfs-cipher-pass: <generated directly in the trusted terminal>
  r2-cipher-pass: <generated directly in the trusted terminal>
```

The eventual Nix change must declare each secret as a raw file owned by
`postgres:postgres` with mode `0400`. The config generator should read those
files, reject empty or multiline values, and write the generated pgBackRest
configuration with mode `0640`. It must never print passphrases or an
unredacted generated configuration.

Do not add placeholder values to the encrypted SOPS document. Do not render
unsubstituted variables into `/etc/pgbackrest.conf`.

## Migration Phases

### Phase 0: Legacy

This is the current state. The active configuration contains two repositories:

| Repo | Role | Namespace |
| --- | --- | --- |
| repo1 | NAS backup and PITR | legacy NFS path |
| repo2 | Offsite backup and PITR | legacy R2 path |

All current timers, metrics, alerts, preseed logic, and restore drills continue
to use repo1 and repo2.

### Phase 1: Bridge

The bridge configuration temporarily contains four repositories:

| Repo | Role | Namespace |
| --- | --- | --- |
| repo1 | Legacy NAS rollback source | existing NFS path |
| repo2 | Legacy offsite rollback source | existing R2 path |
| repo3 | Encrypted NAS candidate | new NFS path |
| repo4 | Encrypted offsite candidate | new R2 path |

Only repo3 and repo4 receive `repo-cipher-type=aes-256-cbc` and their matching
`repo-cipher-pass` values.

This bridge is intentional. With multiple repositories configured,
`archive-push` attempts to archive each WAL segment to every repository.
`archive-async` keeps PostgreSQL availability decoupled from repository
latency, but the spool queue must be watched throughout the bridge.

Activation requirements:

1. Acquire the shared pgBackRest backup lock and pause all pgBackRest timers.
2. Verify no backup, expiration, check, or restore-drill service is active.
3. Generate and validate the four-repository config without printing it.
4. Run `stanza-create`; existing stanzas are skipped and new repos are
   initialized.
5. Force a WAL switch and confirm repo3 and repo4 each receive the segment.
6. Resume normal timers only after the spool queue returns to zero.

Abort the bridge if either new repository cannot accept WAL, if the spool queue
approaches its configured 16 GiB limit, or if any current repo becomes
unhealthy.

### Phase 2: Encrypted Baselines

While the bridge remains active, create independent full backups:

```bash
pgbackrest --stanza=main --repo=3 --type=full --no-expire-auto backup
pgbackrest --stanza=main --repo=4 --type=full --no-expire-auto backup
```

Run them sequentially under the shared lock. Do not run expiration against
repo3 or repo4 during migration.

Extend the disposable restore-drill builder to accept repo3 and repo4, then run
both physical drills. Each drill must prove:

- restore and WAL retrieval remain pinned to the selected repository;
- PostgreSQL 17 completes archive recovery on a private socket;
- every connectable database can be queried;
- the disposable instance stops and scratch data is removed;
- success metrics include the candidate repository identity.

Do not cut over based on `check`, `verify`, or backup completion alone.

### Phase 3: Cutover

Cutover renumbers the encrypted namespaces to the normal operational contract:

| Repo | Role | Namespace |
| --- | --- | --- |
| repo1 | Encrypted NAS backup and PITR | new NFS path |
| repo2 | Encrypted offsite backup and PITR | new R2 path |

Generate a separate read-only legacy config that retains the old repo1/repo2
paths and existing R2 credentials. It is for explicit recovery commands only;
no timer or archive command may consume it.

Before switching:

1. Confirm current-system full backups and successful drills in repo3 and
   repo4.
2. Confirm the archive spool is empty and all four repos have current WAL.
3. Pause timers and drain all pgBackRest services.
4. Save the exact legacy and bridge configurations in the encrypted recovery
   record, without copying decrypted credentials into Git.

After switching:

1. Run `stanza-create` against the renumbered encrypted config.
2. Force a WAL switch and verify both new operational repos advance.
3. Run full backups to new repo1 and repo2.
4. Run both normal repo1/repo2 restore drills.
5. Resume timers only after metrics and spool state are healthy.

The deployment guard, orchestrator, preseed fallback, metrics, alerts, and
protection manifest can continue using repo1/repo2 after this renumbering.

### Phase 4: Observation and Cleanup

Freeze legacy namespaces after cutover. Do not run normal expiration against
them. Retain them until both conditions are true:

- at least 30 days have elapsed; and
- two encrypted restore drills completed after the cutover drill.

Deleting either legacy namespace is destructive and requires explicit operator
approval. Capture the final backup labels, system IDs, timestamps, and deletion
date in the recovery record first.

## Rollback

Before cutover, rollback means restoring the two-repository legacy config.
Because the bridge archived WAL to all four repos, legacy recovery continuity
is preserved.

After cutover, first restore the four-repository bridge config rather than
switching directly to legacy-only operation. This resumes forward WAL delivery
to both generations while preserving access to encrypted backups. Any WAL gap
in the frozen legacy repos must be assessed before claiming new legacy PITR
coverage.

Never delete encrypted metadata, rotate a repository passphrase, or run
`stanza-delete` as a rollback action.

## Implementation Checklist

- [ ] Operator decisions recorded.
- [ ] SOPS passphrase files created directly by the operator.
- [ ] Migration phase option defaults to `legacy`.
- [ ] Assertions reject bridge/encrypted phases without both secrets.
- [ ] Generator supports `legacy`, `bridge`, and `encrypted` outputs.
- [ ] Generated configs are atomic, redacted, and mode `0640`.
- [ ] Bridge services include repo3/repo4 baseline and restore drills.
- [ ] Metrics distinguish candidate and operational repositories.
- [ ] Preseed remains on legacy repo1/repo2 until final cutover.
- [ ] Build, flake, promtool, and rendered ShellCheck validations pass.
- [ ] Bridge deployed in a declared maintenance window.
- [ ] Encrypted repo3 and repo4 restore drills pass.
- [ ] Cutover repo1 and repo2 restore drills pass.
- [ ] Legacy retention gate recorded before deletion.

## Validation Record

Record the following for every phase transition:

- Git revision and Forge system closure;
- active migration phase;
- repository paths without credentials;
- current PostgreSQL system ID;
- latest full backup label per repository;
- newest archived WAL per repository;
- spool bytes and queued file count;
- restore-drill duration, PostgreSQL version, and database count;
- operator approval and rollback decision.
