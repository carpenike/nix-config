# Runbook: Audit Remediation Deploy

Deploy and operations runbook for the audited-improvements branch
(`claude/nix-home-config-review-h8gwh4`) — backup/DR offsite coverage,
monitoring blind-spot fixes, fleet-wide container hardening, and host
resilience changes across **forge**, **luna**, and **nixpi**.

This branch is mostly declarative, but a handful of steps happen **outside**
Nix (live ZFS datasets, sops secrets, NAS exports, router config). Do those
in the order below.

---

## 1. Pre-Deploy Checklist

- [ ] Review the branch: `git log origin/main..HEAD --stat`
- [ ] CI is green (flake eval + build for all hosts)
- [ ] Local sanity check: `task nix:validate` (or `nix flake check`)
- [ ] Build without switching:
  `task nix:build-nixos host=forge` (repeat for `luna`, `nixpi`)
- [ ] Confirm you have console/OOB access to forge and luna in case a reboot
  goes sideways (both run unattended auto-upgrades; this deploy touches boot
  loader config and ZFS tooling)

---

## 2. Required Manual Steps

Do these **before** (or immediately around) the deploy of the host they
apply to. Each is safe to do ahead of time.

### 2.1 forge: create the `rpool/dutyfree` reservation dataset

The two-disk disko layout declares a 15G unmounted reservation on `rpool` so
a full root pool can't wedge the host (CoW needs free space to delete). Disko
only runs at provisioning time, so on the live host create it manually:

```bash
ssh forge.holthome.net
sudo zfs create -o mountpoint=none -o reservation=15G rpool/dutyfree
zfs get reservation rpool/dutyfree   # verify: 15G
```

If `rpool` has less than ~20G free, shrink the reservation accordingly and
grow it after cleanup — the exact size matters less than it existing.

### 2.2 luna: add the restic repository password secret

`hosts/luna/default.nix` now declares `sops.secrets."restic/password"`. The
key must exist in the sops file **before** deploying luna or the build's
activation will fail to render it:

```bash
sops hosts/luna/secrets.sops.yaml
# add:
#   restic:
#     password: <same repository password as forge, or a new one>
```

Reusing forge's restic repository password is fine (separate repository,
same passphrase) — but record whichever you choose in your password manager;
losing it means losing the backups.

### 2.3 nas-1: create/export the luna restic path

Luna mounts `nas-1.holthome.net:/mnt/backup/luna/restic` (NFS v4.2,
automount). nas-1 is itself managed by this repo and its exports are
**declarative**, so this is a small follow-up config change plus a dataset
creation:

1. Create the dataset on nas-1 (one-off, mirrors what
   `hosts/nas-1/infrastructure/zfs-receive.nix` does for forge):

   ```bash
   ssh nas-1.holthome.net
   sudo zfs create -p backup/luna/restic
   sudo zfs set recordsize=1M backup/luna/restic
   ```

2. The export and a fallback directory (tmpfiles) are already declared on
   this branch in `hosts/nas-1/infrastructure/nfs.nix` — the dataset from
   step 1 mounts over the empty fallback directory and takes precedence.

3. Deploy nas-1: `task nix:apply-nixos host=nas-1 NIXOS_DOMAIN=holthome.net`

Verify from luna after its deploy: `ls /mnt/nas-backup` (automount triggers
on access), then `sudo systemctl start restic-init-nas-primary.service`.

### 2.4 Mikrotik: add nixpi as secondary DNS

nixpi now runs a second AdGuardHome instance mirroring luna's config. For it
to actually remove the DNS SPOF, clients must learn about it:

- In the Mikrotik DHCP server settings, add nixpi's IP as the **secondary**
  DNS server (luna `10.20.0.15` stays primary).
- Update any static DNS client configs (servers with hardcoded resolvers).

Do this **after** nixpi is deployed and answering queries
(`dig @<nixpi-ip> forge.holthome.net`).

---

## 3. Optional / Deferred Steps

None of these block the deploy. Each is deliberately left disabled or
manual; do them when convenient.

### 3.1 nixpi: AdGuardHome UI password

nixpi's AdGuardHome runs **without a declarative admin user** because
`networking/adguardhome/password` doesn't exist in
`hosts/nixpi/secrets.sops.yaml` yet (sops-nix fails the build for missing
keys). The UI binds `127.0.0.1:3000` only (reach it via
`ssh -L 3000:127.0.0.1:3000 nixpi`), so no-auth is acceptable short-term.
To enable auth:

1. `sops hosts/nixpi/secrets.sops.yaml` → add
   `networking/adguardhome/password` (same bcrypt value as luna's).
2. Uncomment the secret block in `hosts/nixpi/secrets.nix`.
3. In `hosts/nixpi/dns.nix`, remove `passwordSecret = null` and the
   `users = [ ]` override.

### 3.2 forge: Redis authentication

Redis is now bound to `127.0.0.1` + the podman0 bridge gateway (`10.88.0.1`)
instead of `0.0.0.0`, but still runs **without a password**
(`protected-mode = "no"` so containers can connect). To add auth later:

1. Add a sops secret (e.g. `redis/password`) to forge secrets.
2. Set `services.redis.servers.default.requirePassFile` to it.
3. Plumb the password into tracearr (the only consumer) via an environment
   file: `redis://:<password>@host.containers.internal:6379/0`.

### 3.3 forge: pgBackRest repo2 (R2) client-side encryption

Plumbing exists in `hosts/forge/services/pgbackrest.nix` behind
`modules.services.backup.postgres.pgbackrest.repo2Cipher` — **disabled by
default** and intentionally so.

!!! danger "Destructive re-baseline required"
    A cipher **cannot be added to an existing pgBackRest repository**.
    Enabling repo2Cipher requires deleting all existing repo2 backups in R2
    and taking a fresh full backup. Until the new full backup completes,
    offsite PostgreSQL DR coverage is **gone**. Verify repo1 (NAS) has a
    recent full backup before starting.

Procedure:

1. Add a sops secret (e.g. `pgbackrest/repo2-cipher-pass`) and set
   `repo2Cipher.passphraseFile` to its rendered path; set
   `repo2Cipher.enable = true`; deploy.
2. Delete the repo2 contents in the R2 bucket.
3. Re-initialize and re-baseline:
   ```bash
   sudo -u postgres pgbackrest --stanza=main --repo=2 stanza-create
   sudo -u postgres pgbackrest --stanza=main --repo=2 --type=full backup
   ```
4. Verify: `sudo -u postgres pgbackrest --stanza=main check`

### 3.4 luna: verify gid 999 is free for `onepassword-connect`

Luna now declares `users.groups.onepassword-connect = { gid = 999; }` so the
1Password Connect credentials file can be `0440` group-readable by the
container's `opuser` (uid/gid 999). Before deploying luna, confirm gid 999
isn't already taken by something else:

```bash
ssh luna.holthome.net 'getent group 999'
```

If it's taken, the group assignment needs a different strategy (that's a
`.nix` change — flag it rather than working around it live).

---

## 4. Deploy Order

Recommended order: **nixpi → luna → forge**.

1. **nixpi first** — brings the secondary DNS resolver up while luna is
   still untouched. After it answers queries, do the Mikrotik DHCP change
   (§2.4). From this point DNS survives luna maintenance.
2. **luna second** — this deploy enables the host firewall, turns on
   auto-upgrades (05:15, after forge's window, because forge's upgrade pull
   needs luna's DNS), persists `/var/lib/AdGuardHome`, and starts the
   unified backups. Requires §2.2 and §2.3 done first.
   After switching, spot-check DNS still answers and SSH/UniFi/Omada are
   reachable (the firewall is new — module-opened ports are documented in
   `hosts/luna/default.nix`).
3. **forge last** — the biggest change set. Requires §2.1 done (the dutyfree
   dataset is independent of the rebuild, but do it while you're in there).

```bash
task nix:apply-nixos host=nixpi
task nix:apply-nixos host=luna NIXOS_DOMAIN=holthome.net
task nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net
```

Avoid deploying during the auto-upgrade windows (forge 04:00–05:00, luna
05:15–06:00 after this deploy) so a manual switch doesn't race an unattended
one.

### What restarts on forge

**Effectively all podman containers restart** during the switch: the factory
now emits different container CLI arguments (loopback port publish via
`bindAddress`, `--security-opt=no-new-privileges`, `--cap-drop=ALL` for
non-root containers, removal of `--pull=newer`), and systemd restarts a
container whenever its ExecStart changes. Expect a few minutes of general
service churn — plan for a maintenance window rather than a quiet lunchtime
switch.

Also restarting: Redis (new bind list), PostgreSQL (sharedBuffers 1GB),
Home Assistant (new MemoryHigh/MemoryMax), promtail/loki/prometheus/grafana
(new scrape configs, alerts, dashboards), sshd (GatewayPorts removed).

---

## 5. Post-Deploy Verification

### 5.1 Prometheus targets (metrics auto-discovery now live)

The discovery pipeline now feeds forge's native Prometheus hub. Check
`https://prom.holthome.net/targets`:

- `service-gatus`, `service-loki`, `service-promtail` (and other
  `service-*` discovered jobs) — **UP**
- `grafana-oncall` — UP
- No unexpected `service-*` targets: a target appearing here means its
  module declares `metrics.enable = true`; anything without a real
  `/metrics` endpoint showing up is a regression.

### 5.2 Prime the zpool error exporter

The timer fires 3 minutes after boot / every 5 minutes, but prime it so the
new alerts have data immediately:

```bash
ssh forge.holthome.net 'sudo systemctl start zpool-errors-exporter.service'
curl -s localhost:9100/metrics | grep zfs_pool_vdev_errors | head
```

### 5.3 Grafana dashboards

In Grafana, confirm the **Forge** folder contains the three provisioned
dashboards (Host Overview, ZFS & Backups, Alerts Overview) and that panels
render data (they resolve the Prometheus datasource via a hidden
`DS_PROMETHEUS` variable).

### 5.4 Gatus endpoints

The status page should now show auto-contributed endpoints for every
reverse-proxied factory service (grouped Media / Productivity /
Infrastructure / ...), plus the 11 manually added non-factory checks.
Everything should go green within a couple of check intervals; SSO-protected
vhosts are expected to pass via redirect (`[STATUS] < 400`).

### 5.5 Backups: offsite runs and verification timers

```bash
ssh forge.holthome.net "systemctl list-timers 'restic-backup-*' 'backup-*'"
```

Expect to see:

- `restic-backup-service-*` (nas-primary jobs, 00:00–04:00 window)
- `restic-backup-offsite-*` (9 offsite clones, 05:00 + up to 4h delay)
- `restic-backup-system-state` and `restic-backup-system-state-offsite`
- `backup-verify-nas-primary`, `backup-verify-r2-offsite` (weekly) and
  `backup-restore-test-*` (monthly) — these timers are **new**: the
  verification and restore-test services previously existed but were never
  scheduled
- `backup-expected-jobs-metrics` (daily)

Kick one offsite job manually rather than waiting overnight:

```bash
sudo systemctl start restic-backup-offsite-paperless.service
journalctl -u restic-backup-offsite-paperless -f
```

Then confirm the first `system-state` run completes **without**
`restic_backup_partial` firing (partial = files unreadable; the privileged
CAP_DAC_READ_SEARCH grant should prevent that). On luna, additionally check
`luna-backup-dumps.service` succeeded and `/var/lib/backup-dumps/` contains
fresh `adguardhome/`, `unifi/`, `omada/` trees.

### 5.6 Container hardening: watch first startups

`no-new-privileges` is new for every container. Images whose entrypoints use
sudo/setuid tricks may fail at startup. Watch the first boot of the usual
suspects:

```bash
podman ps --format '{{.Names}} {{.Status}}'
journalctl -u podman-tududi -u podman-tdarr -u podman-dispatcharr --since -15m
# on luna: podman-omada, podman-unifi
```

If a container crash-loops with permission errors immediately after this
deploy, the opt-out is per-service:

```nix
modules.services.<name>.hardening.allowPrivilegeEscalation = true;
```

(and `hardening.capAdd = [ ... ]` for missing capabilities on non-root
containers). netvisor now runs with `NET_RAW`+`NET_ADMIN` instead of
`--privileged`; if scanning features break, the escape hatch is
`modules.services.netvisor.daemon.privileged = true`.

### 5.7 One-time expected events

- **EMQX**: generates a random Erlang cookie into
  `<dataDir>/.erlang.cookie` on first start (replaces the old deterministic
  hostname-hash cookie). One-time restart blip; single-node, so no cluster
  pairing to worry about.
- **tracearr**: image moves from `latest` to pinned `1.3.8` — if `latest`
  had drifted ahead, this is a deliberate downgrade; confirm it starts and
  talks to Redis.
- **apprise**: the factory migration fixes a bug where
  `reverseProxy.caddySecurity` was silently dropped — the PocketID policy
  configured on the host now actually applies. Anything that talked to
  apprise unauthenticated through Caddy will start seeing the auth portal.
- **Zigbee2MQTT / Z-Wave JS UI etc.** reconnect to EMQX after its restart.

### 5.8 ZED sanity test

ZED is re-enabled with filtered zedlets — clean events must stay silent:

```bash
ssh forge.holthome.net 'sudo zpool scrub rpool'
# wait for completion (small pool, minutes):
zpool status rpool
```

A clean scrub should produce **no** Pushover notification (the
`scrub_finish` zedlet only alerts when the scrub surfaces errors). If you
get pinged for a healthy scrub, the zedlet filtering regressed.

### 5.9 General

```bash
systemctl --failed                    # on all three hosts
curl -sI https://status.holthome.net  # Gatus status page reachable
dig @10.20.0.15 plex.holthome.net     # luna DNS
dig @<nixpi-ip> plex.holthome.net     # nixpi DNS
```

---

## 6. Rollback

### Whole-host rollback

Every host keeps 10 boot generations (`systemd-boot configurationLimit`):

- Soft rollback: `nixos-rebuild switch --rollback` (or
  `task nix:apply-nixos` from the previous commit).
- Hard rollback: reboot and pick the previous generation in the systemd-boot
  menu. This is also the recovery path for a kernel/ZFS-module mismatch
  after an auto-upgrade (`zfs_unstable` caveat — do not downgrade the ZFS
  package casually once pools have newer features enabled).

Rolling back forge **before the first offsite run** loses nothing; after
offsite runs have happened, the R2 repository simply stops receiving clones
(no cleanup needed).

### Targeted rollbacks (no full revert needed)

| Symptom | Knob |
|---------|------|
| Container fails under no-new-privileges | `modules.services.<name>.hardening.allowPrivilegeEscalation = true` |
| Non-root container missing a capability | `modules.services.<name>.hardening.capAdd = [ "..." ]` |
| Service unreachable after loopback publish | `modules.services.<name>.bindAddress = "0.0.0.0"` (prefer fixing the Caddy route instead) |
| netvisor scanning broken | `modules.services.netvisor.daemon.privileged = true` |
| Offsite jobs overloading uplink | trim `modules.services.backup.restic.offsite.services` (per-host list) |
| ZED notifications too noisy | `modules.filesystems.zfs.zed.pushNotifications = false` |
| Gatus auto-endpoints unwanted for a service | `modules.services.<name>.gatus.enable = false` |
| oomd killing the wrong thing on forge | tune the per-service `MemoryHigh`/`MemoryMax` caps before disabling `systemd.oomd` |

Manual steps (§2) are all additive and safe to leave in place across a
rollback: the dutyfree dataset, luna's sops key, the nas-1 export, and the
Mikrotik secondary DNS entry are inert under the old configuration.
