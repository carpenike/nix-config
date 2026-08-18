# Disaster Recovery Drills

A backup that has never been restored is a hypothesis. This document is the
register of recovery drills: what each one proves, how to run it, and when it
last actually ran.

A drill is only "done" when its row in the register below carries a date and an
operator. An automated drill that runs but is not alerted on is not done either
— it is the same failure shape as a backup nobody checks.

---

## Register

| Drill | Proves | Cadence | Automated | Last run | Result |
| --- | --- | --- | --- | --- | --- |
| pgBackRest repo1 restore | PostgreSQL is restorable from the NAS repository | Weekly (Sat 09:00) | Yes — `pgbackrest-restore-drill-repo1.timer` | See `pgbackrest_restore_drill_last_success_timestamp_seconds{repo="1"}` | — |
| pgBackRest repo2 restore | PostgreSQL is restorable from Cloudflare R2 | Weekly (Sun 10:00) | Yes — `pgbackrest-restore-drill-repo2.timer` | See `pgbackrest_restore_drill_last_success_timestamp_seconds{repo="2"}` | — |
| PGP decrypts the sops tree | The offline key still opens `*.sops.yaml` | Continuous | No — but exercised by ordinary use | Every secrets edit | **PASS** (in routine use) |
| `/persist` restore from nas-1 | A rebuilt host recovers its identity onsite | Per rebuild | No — `task bootstrap:remote-install RECOVER=true` | Multiple rebuilds | **PASS** |
| **`/persist` restore from R2** | **Recovery survives losing nas-1 too** | **Annual** | **No** | **NEVER RUN** | **UNPROVEN** |

The two pgBackRest drills were built well before they were scheduled; they had
never run outside a manual `systemctl start` until the timers landed on
2026-08-17. Their alert rules (`PgBackRestRestoreDrillFailed`,
`PgBackRestRestoreDrillStale`, `PgBackRestRestoreDrillMetricsAbsent`,
`PgBackRestRestoreDrillUnitFailed`) are what keep them from silently stopping
again.

### Correction, 2026-08-18

This register's first version carried a single row claiming the whole PGP
recovery path was NEVER RUN and total site loss was UNPROVEN. That was wrong,
and the way it was wrong is worth keeping: it reasoned from the code alone and
never asked the operator what he had actually done.

Two of the three links above are exercised and were already exercised then:

* **The PGP key is in routine use.** There is no age identity on the operator's
  Mac (no `~/.config/sops/age/keys.txt`, no `SOPS_AGE_*` in the environment),
  so sops there can only decrypt through PGP. Every edit of a `*.sops.yaml`
  exercises the link. The primary secret key is offline (`sec#`) and the
  subkeys live on a hardware token (`ssb>`); the encryption subkey
  `CA1222AB47BE783C` expires **2027-10-22**.
* **Restoring `/persist` onsite is battle-tested.** `task
  bootstrap:remote-install host=<host> RECOVER=true` has been run across
  several rebuilds. It restores `rpool/safe/persist` and `rpool/safe/home`
  from nas-1 with syncoid, authenticated by the operator's forwarded SSH
  agent — see `.taskfiles/bootstrap/Taskfile.yaml`.

What neither of those touches is Cloudflare R2. `RECOVER=true` reads from
nas-1, so every proven recovery to date assumes nas-1 survived. The
`system-persist-offsite` Restic job that makes an R2 restore possible at all
only began running on 2026-08-18, so it has never been restored from.

The remaining gap is therefore narrow and specific: **the R2 leg**, which is
exactly the leg that matters when the failure takes the whole building.

---

## Offsite (R2) identity recovery drill

### What it proves

That `/persist` can be recovered from Cloudflare R2 — that is, that recovery
works when nas-1 is gone too.

It is deliberately NOT a test of the PGP key. That link is exercised every time
someone edits a secrets file (see the correction above). What has never been
done is walking the chain all the way into the offsite repository and pulling
the identity back out of it.

### Why this specific leg

forge's SOPS identity is derived from `/etc/ssh/ssh_host_ed25519_key`
(`sops.age.sshKeyPaths`, `hosts/forge/secrets.nix`). That key lives in
`/persist`. So in a total loss:

1. `/persist` is gone, therefore forge's age identity is gone.
2. Without that identity nothing in `*.sops.yaml` can be decrypted — including
   `restic/password` and `restic/r2-prod-env`.
3. Without those, the offsite Restic repository in R2 is unreadable — including
   the `system-persist-offsite` copy of `/persist` itself.

The offline PGP key `DA80 0206 0402 EC39 B195 451D 5CED 8036 2B5A 4EF2` is what
breaks the cycle — `.sops.yaml` lists it as a recipient on every `*.sops.yaml`.
The chain is:

```
offline PGP key
  -> decrypt hosts/forge/secrets.sops.yaml directly from the git repo
  -> restic/password + restic/r2-prod-env
  -> restore /persist from the R2 Restic repository
  -> forge's age identity is back, and normal recovery can proceed
```

Link 1 is proven by daily use. Link 2 is a file read. **Links 3 and 4 have never
been performed against R2** — every recovery to date used `RECOVER=true`, which
pulls from nas-1 instead. So the chain is proven end-to-end only for failures
that spare the NAS, which excludes precisely the fire/flood/theft cases the
offsite copy exists for.

Concretely unproven, and each of these has bitten someone somewhere:

* that the R2 credentials in sops are current and still authorise reads
* that the Restic repository is initialised, reachable and holds a
  `system-persist-offsite` snapshot with real content
* that a restored `ssh_host_ed25519_key` round-trips to the same age identity
  forge actually uses
* that the exclusions on the job (`**/var/log/**`, `**/var/lib/cache/**`)
  didn't remove something recovery needs

### Running the drill

Do this on a machine that is **not** forge, from a checkout of this repo, with
the hardware token attached. Running it on forge would use forge's own age
identity and its NFS-mounted repositories, and would prove nothing about
recovering without them — the whole scenario is that forge no longer exists.
The operator's Mac is the natural place: it already has the token and no age
identity, so the isolation this drill needs is its normal state.

1. Confirm the key is present and not expired:

    ```bash
    gpg --list-secret-keys --keyid-format LONG DA8002060402EC39B195451D5CED80362B5A4EF2
    ```

    Check `expires:` on the `[E]` encryption subkey — that is the one sops uses.
    As of 2026-08-18 it is `CA1222AB47BE783C`, expiring **2027-10-22**. Extend it
    before then rather than discovering it during an outage; a key that expires
    between drills is a silent failure. `sec#` and `ssb>` are expected here and
    are not problems: they mean the primary secret is kept offline and the
    subkeys live on a hardware token, so the token must be attached.

2. Decrypt a secret using **only** that key. Unset any age identity first so a
   stray `SOPS_AGE_KEY_FILE` cannot satisfy the decryption and produce a false
   pass:

    ```bash
    env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE sops --decrypt --extract '["restic"]["password"]' hosts/forge/secrets.sops.yaml
    ```

    This must prompt for the PGP passphrase. If it returns a value **without**
    prompting, the drill is invalid — something else decrypted it.

3. Prove the recovered credentials actually open the offsite repository. Using
   the password from step 2 and the R2 credentials from
   `restic/r2-prod-env` in the same file:

    ```bash
    restic -r "s3:https://<r2-endpoint>/<r2-bucket>/forge" snapshots --tag identity
    ```

    A snapshot list containing `system-persist-offsite` is the pass condition.
    Anything else means the chain is broken somewhere after the key.

4. Restore the identity file to a scratch directory and confirm it is the real
   thing rather than an empty or truncated file:

    ```bash
    restic -r "s3:https://<r2-endpoint>/<r2-bucket>/forge" restore latest \
      --tag identity --target /tmp/dr-drill
    ssh-keygen -l -f /tmp/dr-drill/**/etc/ssh/ssh_host_ed25519_key
    ```

    The fingerprint must match forge's live host key. Then remove the scratch
    directory — it contains a live private key.

    ```bash
    rm -rf /tmp/dr-drill
    ```

5. Record the result in the register above: date, operator, and pass/fail. A
   drill that ran but was not recorded did not happen, because the next person
   cannot tell.

### After a pass: build `RECOVER_SOURCE=r2`

Running this by hand proves the path exists. It does not make the path
*usable under stress*, which is the point of a recovery mechanism.

`docs/analysis/forge-backup-recovery-improvement-plan.md` already carries the
follow-up: *"Add `RECOVER_SOURCE=nas|r2` after offsite system backups exist."*
That precondition was met on 2026-08-18. Today
`task bootstrap:remote-install host=<host> RECOVER=true` restores from nas-1
only — hard-coded to `ryan@nas-1:backup/<host>/zfs-recv/...` — so in a
lost-the-building scenario the operator is improvising Restic commands from
memory during the worst week of their year.

Once this drill passes, the commands it used are the specification for that
task. Write them down there while they are fresh.

### Failure modes worth naming

- **R2 credentials stale or revoked.** The most likely failure, and invisible
  day to day: nothing else in the system reads `restic/r2-prod-env` from a
  machine that is not forge.
- **Repository unreachable or empty.** A Restic job that runs and reports
  success still proves nothing until something reads the repository back.
- **Restored key does not match.** If the fingerprint in step 4 differs from
  forge's live host key, the offsite copy is of the wrong thing, and every
  conclusion drawn from "offsite-backup: covered" is wrong with it.
- **Step 2 passes without prompting.** Not a pass. Re-run with the environment
  cleared; something supplied an age identity and the isolation was not real.
- **Key expired.** Not currently a risk — `2027-10-22` — but it becomes one
  silently. Extend it well before, and re-encrypt.
- **Passphrase forgotten, or token lost.** There is no recovery from either. If
  neither the passphrase nor a backup token is independently escrowed, the
  drill's real finding is that the escrow does not exist.
