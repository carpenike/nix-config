# Omada Migration: Luna to Forge

**Status:** Completed 2026-07-10

This runbook moves the Omada Controller from `luna` to `forge` without
upgrading Omada. Both controllers must run `5.15.24.19` for this migration.
The v6 upgrade is a separate change after the migrated controller is stable.

Use **Controller Migration**, not Site Migration. Controller Migration moves
the complete controller in three phases: Export Controller, Migrate Controller,
and Migrate Devices. Site Migration is only for moving selected sites between
controllers.

!!! danger "Use Controller Migration, not the MongoDB files"
   Keep an independent UI backup, then follow the Controller Migration wizard.
   Do not copy `/var/lib/omada` or `/opt/tplink/EAPController/data` between
   hosts. A filesystem copy can leave the embedded MongoDB database
   inconsistent or incompatible.

## Before the Maintenance Window

1. Validate both host configurations:

   ```bash
   nix flake check
   task nix:build-nixos host=forge NIXOS_DOMAIN=holthome.net
   task nix:build-nixos host=luna NIXOS_DOMAIN=holthome.net
   ```

2. Confirm that Luna is healthy and still runs Omada v5:

   ```bash
   ssh luna.holthome.net \
     'systemctl is-active podman-omada.service && \
      sudo podman inspect omada --format "{{.ImageName}}" && \
      sudo cat /var/lib/omada/data/LAST_RAN_OMADA_VER.txt'
   ```

3. In the Luna controller, open **Settings > Maintenance > Backup**, create a
   fresh backup, and download it to the administration workstation.

4. Keep the backup outside this repository and record its checksum:

   ```bash
   shasum -a 256 /path/to/omada-backup
   ```

Do not continue without a non-empty backup file. Keep Luna running and retain
its `/var/lib/omada` data until the observation period is complete.

For controller versions `5.13.11.41` and later, Omada requires the source and
target backup versions to have the same Major.Minor.Patch components. The exact
`5.15.24.19` image pin on both hosts satisfies this requirement.

## Provision Forge on v5

Deploy only `forge` first. Do not apply Luna's removal yet.

```bash
task nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net
```

Verify the fresh controller and its ZFS dataset:

```bash
ssh forge.holthome.net \
  'systemctl is-active podman-omada.service && \
   sudo zfs list tank/services/omada && \
   sudo podman inspect omada --format "{{.ImageName}}"'
curl -kI https://10.20.0.30:8043
```

At this point `omada.holthome.net` must still resolve to Luna. Use the direct
Forge address, `https://10.20.0.30:8043`, for setup and validation.

## Run Controller Migration

Schedule this phase for a maintenance window. Omada warns that wireless clients
may disconnect and connectivity may be interrupted for several minutes while
the devices change controllers.

### 1. Export Controller on Luna

1. In Luna's **Global View**, open
   **Settings > Migration > Controller Migration** and click **Start**.
2. In **Export Controller**, select the required settings and retained data,
   then export and save the migration backup.
3. Keep this export in addition to the independent Maintenance backup.

### 2. Import Controller on Forge

1. Open `https://10.20.0.30:8043` and accept the controller's temporary
   self-signed certificate.
2. Import the Luna migration backup using the fresh controller's restore flow.
   Depending on the v5 screen presented, this is available during initial setup
   or under **Global View > Settings > Maintenance > Backup & Restore**.
3. Wait for the controller to restart. Do not interrupt the import.
4. Confirm that Forge reports version `5.15.24.19` and that the SLC site,
   networks, administrators, devices, and historical configuration are present.
5. Return to Controller Migration on Luna and click **Confirm** only after the
   import has completed successfully.

!!! warning "Do not skip the Forge import"
    TP-Link explicitly warns that on controller `5.15.24` and later, migrating
    devices before importing the controller backup prevents the target from
    adopting them automatically.

### 3. Migrate Devices to Forge

1. On Luna's **Migrate Devices** step, enter `10.20.0.30` as the target
   **Controller IP/Inform URL**.
2. Select all managed devices. This installation currently has one switch and
   four access points.
3. Click **Migrate Devices** and wait for the devices to move to Forge.
4. On Forge, verify that all five devices appear and reach **Connected**. Also
   verify client counts and make a harmless configuration change on a
   non-critical device.
5. Do not click **Forget Devices** on Luna yet.

Use the direct Forge address throughout this phase so the production hostname
continues to reach Luna.

## Cut Over Devices and DNS

1. In Mikrotik DNS, change `omada.holthome.net` from
   `luna.holthome.net`/`10.20.0.15` to
   `forge.holthome.net`/`10.20.0.30`.
2. Flush the administration workstation's DNS cache if needed, then verify:

   ```bash
   dig +short omada.holthome.net
   curl -kI https://omada.holthome.net
   ```

3. Confirm again that every switch and access point remains **Connected** on
   Forge.
4. Only after all checks pass, click **Forget Devices** on Luna to finish the
   Controller Migration workflow.
5. Stop Omada on Luna:

   ```bash
   ssh luna.holthome.net 'sudo systemctl stop podman-omada.service'
   ```

Do not run two restored controllers against the same devices after the
migration is accepted.

## Roll Back

Before clicking **Migrate Devices**, rollback is simple: stop Forge and continue
using Luna. After device migration, changing DNS and restarting Luna is not
enough because the devices' inform address now points to Forge.

If rollback is required after clicking **Migrate Devices**:

1. Do not click **Forget Devices** on Luna.
2. While both controller records still exist, use the controller migration or
   device-management flow to point all devices back to Luna at `10.20.0.15`.
3. Verify every device reaches **Connected** on Luna.
4. Restore the Mikrotik DNS record to Luna and verify it resolves to
   `10.20.0.15`.
5. Stop Forge only after Luna is managing every device again:

   ```bash
   ssh forge.holthome.net 'sudo systemctl stop podman-omada.service'
   ```

If the migration UI cannot move devices back, manually reset their inform URL
or re-adopt them on Luna using the existing device credentials. Luna's NixOS
configuration and persistent data remain unchanged until final decommissioning.

## Decommission Luna

After Forge has remained healthy for the agreed observation period:

1. Take another Omada UI backup from Forge and keep it outside the repository.
2. Confirm the Forge backup and ZFS replication jobs have completed.
3. Apply Luna's new configuration:

   ```bash
   task nix:apply-nixos host=luna NIXOS_DOMAIN=holthome.net
   ```

4. Verify `podman-omada.service` no longer exists on Luna and the production
   hostname still reaches Forge.
5. Retain Luna's old persistent data until the rollback window closes. Remove
   it manually only after a tested Forge backup exists.

## Completion Record

The cross-host migration completed on v5 before the controller was upgraded in
place on Forge. The follow-up upgrade converted embedded MongoDB from 3.6 to 8.0
with the upstream one-shot upgrader, then deployed Omada `6.2.10.17` with TCP
port `29817` enabled.

Validated completion state:

- All four access points and the managed switch are connected to Forge.
- `omada.holthome.net` resolves to `10.20.0.30`.
- Restic and Syncoid contain post-v6 recovery points.
- `tank/services/omada@pre-v6-20260709` is held for rollback.
- `/var/lib/omada/data/mongodb-preupgrade.tar` retains the upstream pre-upgrade
   MongoDB archive.
- Luna's original `/persist/var/lib/omada` data remains available during the
   rollback observation period.

The work was tracked by [issue #434](https://github.com/carpenike/nix-config/issues/434).

Reference: [How to migrate Omada Controller with the Migration feature](https://support.omadanetworks.com/en/document/13126/?app=omada)
