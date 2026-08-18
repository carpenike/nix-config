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
| **PGP identity recovery** | **A total site loss is recoverable at all** | **Annual** | **No — requires the offline key** | **NEVER RUN** | **UNPROVEN** |

The two pgBackRest drills were built well before they were scheduled; they had
never run outside a manual `systemctl start` until the timers landed on
2026-08-17. Their alert rules (`PgBackRestRestoreDrillFailed`,
`PgBackRestRestoreDrillStale`, `PgBackRestRestoreDrillMetricsAbsent`,
`PgBackRestRestoreDrillUnitFailed`) are what keep them from silently stopping
again.

---

## PGP identity recovery drill

### What it proves

That the offline PGP key can still decrypt this repository's secrets, and
therefore that a rebuilt-from-nothing forge can reach its own backups.

This is the **single most load-bearing untested assumption in the whole
recovery design**. Everything else has a second path; this does not.

### Why it is the whole ballgame

forge's SOPS identity is derived from `/etc/ssh/ssh_host_ed25519_key`
(`sops.age.sshKeyPaths`, `hosts/forge/secrets.nix`). That key lives in
`/persist`. So in a total loss:

1. `/persist` is gone, therefore forge's age identity is gone.
2. Without that identity nothing in `*.sops.yaml` can be decrypted — including
   `restic/password` and `restic/r2-prod-env`.
3. Without those, the offsite Restic repository in R2 is unreadable — including
   the `system-persist-offsite` copy of `/persist` itself.

The only thing that breaks the cycle is the offline PGP key
`DA80 0206 0402 EC39 B195 451D 5CED 8036 2B5A 4EF2`, which `.sops.yaml` lists
as a recipient on every `*.sops.yaml`. The working chain is:

```
offline PGP key
  -> decrypt hosts/forge/secrets.sops.yaml directly from the git repo
  -> restic/password + restic/r2-prod-env
  -> restore /persist from the R2 Restic repository
  -> forge's age identity is back, and normal recovery can proceed
```

Every link after the first is exercised routinely. The first link is not
exercised by anything, ever. If that key is lost, corrupted, expired, or its
passphrase forgotten, the offsite backups are ciphertext with no key and the
household's data is gone despite three tiers of protection reporting green.

### Running the drill

Do this on a machine that is **not** forge, from a checkout of this repo, with
the offline key's media attached. The point is to prove the key works
independently of any running host — running it on forge would silently use
forge's own age identity and prove nothing.

1. Confirm the key is present and not expired:

    ```bash
    gpg --list-secret-keys --keyid-format LONG DA8002060402EC39B195451D5CED80362B5A4EF2
    ```

    Check the `expires:` field. A key that expires between drills is a silent
    failure — extend it now rather than discovering it during an outage.

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

### Failure modes worth naming

- **Key expired.** Extend the expiry and re-encrypt. Cheap now, fatal later.
- **Passphrase forgotten.** There is no recovery from this. If the passphrase
  is not independently escrowed, the drill's real finding is that the
  escrow does not exist.
- **Media unreadable.** Offline media degrades. If this drill is the only time
  the media is read, an annual read is also the only thing keeping bit rot
  visible.
- **Step 2 passes without prompting.** Not a pass. Re-run in a clean
  environment; something supplied an age identity.
