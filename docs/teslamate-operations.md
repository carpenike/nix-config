# TeslaMate Service Operations

## Stack Overview

- TeslaMate core app published through Podman with pinned image digests for deterministic deploys.
- Optional-but-enabled components on `forge`: local PostgreSQL role/database plus shared services (central Grafana + EMQX MQTT broker).
- Reverse proxy entries for TeslaMate (`teslamate.${domain}`) and the EMQX dashboard (`mqtt.${domain}`) protected via caddy-security/PocketID authentication.
- Restic backups plus ZFS dataset replication (Sanoid) keep `/tank/services/teslamate` synchronized to `nas-1`.
- Prometheus/Loki wiring ensures metrics (`/metrics` on port 4000) and journald logs are exported automatically.

## Bootstrap Checklist

1. **DNS** – Publish `teslamate.<domain>` (TeslaMate UI) and `mqtt.<domain>` (EMQX dashboard) to your public zone.
2. **SSO** – Configure PocketID groups referenced by the modules (TeslaMate UI: `admins`, MQTT dashboard: `admins`).
3. **Secrets** – Add the SOPS entries shown below plus the shared Restic password at `restic/password`.
4. **Dataset** – Create `tank/services/teslamate` (or import from backup) on the target host; permissions land on the `teslamate` system user/group during activation.
5. **Replication Target** – Make sure `nas-1.holthome.net` trusts the `forge` replication key listed in the host module (or update both sides accordingly).
6. **Tesla API Prep** – Generate a long-lived encryption key and ensure you can issue a fresh Tesla API refresh token before first login.

## Secret Matrix

| Key | Purpose | Owner/Mode | Notes |
| --- | --- | --- | --- |
| `teslamate/database_password` | Postgres role password injected into the container and DB provisioning jobs | `root:postgres / 0440` | Used by local Postgres via `modules.services.postgresql.databases`. |
| `teslamate/encryption_key` | `ENCRYPTION_KEY` consumed by TeslaMate to encrypt Tesla refresh tokens | `root:root / 0400` | Generate 256-bit random and keep stable across redeploys. |
| `teslamate/mqtt_password` | Password for the EMQX user `teslamate` | `root:root / 0400` | Shared between TeslaMate and other consumers (e.g., Home Assistant automations). |
| `emqx/dashboard_password` | Admin password for the EMQX web console | `root:root / 0400` | Required whenever the dashboard + reverse proxy are enabled. |
| `restic/password` | Shared Restic repository password used by the `preseed` and scheduled backups | `root:root / 0400` | Existing secret reused from other services. |

> Use `sops hosts/forge/secrets.yaml` (or the Task helper) to add/update these entries; activation will render them at the paths declared in `hosts/forge/secrets.nix`.

## Deploy / Update Flow

1. Edit `hosts/forge/services/teslamate.nix` (or another host) to adjust registry, domains, and caddy-security policies.
2. Validate locally: `nix build .#nixosConfigurations.forge.config.system.build.toplevel --dry-run`.
3. Push to Git, then run `task nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net` to apply.
4. Confirm systemd units are healthy:
  - `systemctl status podman-teslamate.service`
  - `systemctl status podman-emqx.service`
5. Verify ingress via PocketID authentication and ensure Grafana dashboards load via the shared observability stack.

## Backups & Restore

- Restic backups target `nas-primary` via the shared backup module; tags `teslamate` + `telemetry` make filtering easy.
- `preseed` is enabled with `repositoryUrl = /mnt/nas-backup`, so first boot will try syncoid → local restore → Restic (in that order) before starting containers.
- Sanoid replicates `tank/services/teslamate` to `backup/forge/zfs-recv/teslamate` on `nas-1` using the provided host key. Adjust `modules.backup.sanoid.datasets` if you move datasets.
- To perform a manual Restic restore:
  1. Stop TeslaMate containers.
  2. Run `restic -r <repo> restore latest --target /tank/services/teslamate --include teslamate` (password from `restic/password`).
  3. Restart services and watch the importer logs.

## Monitoring & Alerts

- Prometheus automatically scrapes TeslaMate via the shared metrics registry, labeled `service="teslamate"`.
- EMQX exports Prometheus metrics and a container liveness alert (`emqx-service-down`) fires if the broker stops accepting connections.
- Journald logs are shipped via the `logging` submodule; query by `unit="podman-teslamate.service"` (or `podman-emqx.service`) in Loki.
- Notifications inherit the global `modules.notifications` defaults. Failures emit to the `system-alerts` channel unless overridden per-host.

## Operational Tips

- Importing legacy CSVs: drop files into `${dataDir}/import` (default `/var/lib/teslamate/import`) and restart TeslaMate.
- MQTT access for automations: point clients at the shared EMQX host/port (default `localhost:1883` internally, `mqtt.${domain}` if you terminate TLS elsewhere).
- Updating container images: bump the `image` attributes in either the module defaults or host override, run the dry-run build, then reapply NixOS.
- To temporarily pause data collection, stop only the TeslaMate container; the shared Grafana + EMQX services keep their state persisted under their own datasets.
