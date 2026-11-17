# SSH Public Keys for forge

This file contains public SSH keys used by service accounts on forge for documentation and reference.

## ZFS Replication Key

**User:** `zfs-replication`
**Purpose:** SSH authentication to nas-1 for ZFS send/recv replication
**Key Type:** ed25519
**Created:** 2025-10-08
**Restrictions:** Command-restricted to `zfs recv` only on nas-1

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC4aPwHeW7/p2YcKI41srC8X6Cw2D6e5mCbQuVp0USW1 zfs-replication@forge
```

**Usage on nas-1:**
```nix
users.users.zfs-replication.openssh.authorizedKeys.keys = [
  ''command="zfs recv -F backup/forge/zfs-recv",no-agent-forwarding,no-X11-forwarding,no-pty,no-user-rc ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC4aPwHeW7/p2YcKI41srC8X6Cw2D6e5mCbQuVp0USW1 zfs-replication@forge''
];
```

---

## Hank (Hermes) key

**User:** `hank` (on forge: `core/hank.nix`; on rydeck: by hand)
**Purpose:** Hank's SSH from the k8s cluster for incident response: journal and status reads, and on forge polkit restarts/reloads of non-critical services
**Key Type:** ed25519, SHA256:I/xHl0CKom8g8xleeG3kt8CdflLBHMplMgQwEOWimxY
**Created:** 2026-11-16
**Private key:** 1Password `k8s-secrets/hermes-hank`, field `ssh_key`; mounted only in Hank's screen pod
**Restrictions:** `from=` the cluster nodes (10.20.10.20-23), no agent/X11/port forwarding

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDetDxQqVN14Ksfsw68nTOjvHEx0wn+1nUpkX73YMUQs hank@hermes
```

---

## Hank (Hermes) restart-only key

**User:** `hank` on forge (`core/hank.nix`), ssh alias `forge-svc` in Hank's sandbox
**Purpose:** service restarts/reloads without a Hermes approval prompt: sshd forces this key into `hank-svc`, which runs only `systemctl restart|reload <unit>`
**Key Type:** ed25519, SHA256:Z1DisuuKhlS6X/RNAksBsM6QztH1myaq8OSWKrXAXI4
**Created:** 2026-11-16
**Private key:** 1Password `k8s-secrets/hermes-hank`, field `ssh_key_svc`; mounted only in Hank's screen pod
**Restrictions:** `command=hank-svc`, `restrict` (no pty, no forwarding), `from=` the cluster nodes

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBB/HZJLxBhGtzzeARVrp9v+YgA3ufY/eSV4vfCA8ANu hank-svc@hermes
```

---

## Key Rotation Policy

- Review keys annually
- Rotate immediately if compromised
- Update both this file and SOPS secrets when rotating
- Test new keys before removing old ones
