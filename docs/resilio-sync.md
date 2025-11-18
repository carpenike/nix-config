# Resilio Sync Helper Module

Opinionated Resilio Sync orchestration for synchronizing mutable service data (recipes, media indexes, API keys, etc.) via declarative NixOS configuration.

## Why this exists

Cooklang needed a reproducible way to pull personal recipes onto a rebuilt node. Rather than baking Resilio-specific logic into that service, this helper module turns Resilio into shared infrastructure:

- Declarative folder definitions keyed by service name
- Automatic `rslsync` group membership so it can write into service datasets
- Optional tmpfiles enforcement for paths outside ZFS-managed datasets
- Optional per-folder `readOnly` flag to document pull-only replicas and guard against accidental group write bits
- Strict requirement for per-folder secrets (use sops-nix or LoadCredential)
- Sensible service ordering so ZFS datasets are mounted before syncing begins

## Quick start

1. **Generate a Resilio secret on any trusted node:**

   ```bash
   rslsync --generate-secret
   ```

2. **Store it with sops-nix** at `hosts/<host>/secrets.sops.yaml` and expose it under `/run/secrets`:

   ```nix
   # hosts/forge/secrets.nix
   "resilio/cooklang-secret" = {
     mode = "0400";
     owner = "rslsync";
     group = "cooklang";
   };
   ```

3. **Enable the helper module** alongside the service that needs data:

   ```nix
   modules.services.resilioSync = {
     enable = true;
     folders.cooklang = {
       path = "/data/cooklang/recipes";
       secretFile = config.sops.secrets."resilio/cooklang-secret".path;
       group = config.modules.services.cooklang.group;
       ensurePermissions = true;
       owner = config.modules.services.cooklang.user;
       mode = "2770";
       knownHosts = [ "nas-1.holthome.net:4444" ];
     };
   };
   ```

4. **Reload the host** – Resilio will start with the folders listed and begins syncing once peers come online.

> **Heads-up:** The upstream Resilio Web UI stores its password inside the Nix store. This helper keeps it disabled by default. Prefer the declarative folder list unless you absolutely need the UI.

## Consuming synced data

Resilio may need a few seconds (or minutes) to download the initial dataset. Services that assume the synced files exist should wait for `resilio.service` before starting:

```nix
systemd.services.cooklang = {
  after = [ "resilio.service" ];
  wants = [ "resilio.service" ];
};
```

For critical workflows, consider a `systemd.path` or `systemd.timer` that only starts your service once a sentinel file materializes inside the synced directory.

## Configuration reference

`modules.services.resilioSync` exposes the following options:

| Option | Type | Default | Notes |
|--------|------|---------|-------|
| `enable` | bool | `false` | Turns on the helper and the upstream `services.resilio` unit |
| `package` | package | `pkgs.resilio-sync` | Swap in a patched build if needed |
| `deviceName` | string | `config.networking.hostName` | Friendly name visible to peers |
| `listeningPort` | port | `0` | Static port (0 = Resilio picks one) |
| `storagePath` | path (string) | `/var/lib/resilio-sync` | Internal state directory |
| `directoryRoot` | string | `""` | Only relevant if the Web UI is enabled |
| `checkForUpdates` | bool | `false` | Disable phone-home checks by default |
| `useUpnp` | bool | `false` | Keep UPnP off unless a specific network needs it |
| `downloadLimit`/`uploadLimit` | int | `0` | KB/s caps (0 = unlimited) |
| `encryptLAN` | bool | `true` | Always encrypt LAN hops |
| `webUI.*` | submodule | disabled | Exposes upstream Web UI knobs (insecure, stored in store) |
| `apiKey` | string | `""` | Optional developer API token |
| `folders` | attrset | `{}` | Declarative folder definitions (see below) |
| `extraGroups` | list(str) | `[]` | Additional POSIX groups for `rslsync` |
| `afterUnits` / `wantUnits` | list(str) | `["zfs-mount.service" …]` | Extra ordering constraints |

### Folder definition (`folders.<name>`)

| Option | Type | Default | Notes |
|--------|------|---------|-------|
| `path` | string | *(required)* | Absolute directory to sync |
| `secretFile` | string | *(required)* | Path to runtime secret containing the Resilio key |
| `useRelayServer` | bool | `false` | Toggle relay fallbacks |
| `useTracker` | bool | `true` | Allow tracker discovery |
| `useDHT` | bool | `false` | Enable DHT discovery |
| `searchLAN` | bool | `true` | Keep LAN discovery on |
| `useSyncTrash` | bool | `true` | Preserve deletions in `.Sync/Archive` |
| `knownHosts` | list(str) | `[]` | Static peer addresses |
| `group` | string? | `null` | Service group owning the directory. `rslsync` joins automatically |
| `owner` | string? | `null` | Optional owner enforced when `ensurePermissions = true` |
| `mode` | string | `"2770"` | tmpfiles mode (setgid friendly) |
| `ensurePermissions` | bool | `false` | Create path + enforce owner/group/mode via tmpfiles |
| `readOnly` | bool | `false` | Documentation hint for pull-only replicas. When paired with `ensurePermissions`, the helper asserts that the group digit does not include write permissions. |

Assertions guarantee that paths are absolute and that permissions are only enforced when the owner/group fields are set.

## Example: Cooklang recipes

```nix
{ config, ... }: {
  modules.services.cooklang = {
    enable = true;
    recipeDir = "/data/cooklang/recipes";
  };

  modules.services.resilioSync = {
    enable = true;
    deviceName = "forge-recipes";
    folders.cooklang = {
      path = config.modules.services.cooklang.recipeDir;
      secretFile = config.sops.secrets."resilio/cooklang-secret".path;
      group = config.modules.services.cooklang.group;
      owner = config.modules.services.cooklang.user;
      ensurePermissions = true;
      knownHosts = [ "nas-1.holthome.net:4444" ];
    };
  };
}
```

This results in:

- `/data/cooklang/recipes` owned by `cooklang:cooklang` with `2770` permissions
- `rslsync` joining the `cooklang` group so it can write updates
- Resilio waiting for ZFS mounts before it starts syncing
- No Web UI exposed; all folder secrets live under `/run/secrets`

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `resilio.service` fails at boot | Secret path missing (`secretFile` must point to a runtime file). Verify `sops-nix` entry and that the file exists under `/run/secrets`. |
| Files never appear | Confirm the peer uses the same secret and that trackers/known hosts are reachable. Inspect `/var/lib/resilio-sync` logs. |
| Permission denied writing into dataset | Make sure `group` points to the owning service group, `ensurePermissions` sets group write (`2770`), and that `rslsync` is listed in `id rslsync`. |
| Endless resynchronization | Disable `useRelayServer`/`useTracker` to force LAN-only, or restrict `knownHosts` to the machines that should exchange data. |

## Next steps

- Wire additional services (e.g., `dispatcharr`, media configs) into `folders.*`
- Consider adding a host-level Restic policy to capture `/var/lib/resilio-sync` so license keys and state survive rebuilds
- Document peer bootstrap in `docs/cooklang-service.md` once secrets exist
