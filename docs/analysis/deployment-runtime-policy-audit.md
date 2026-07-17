# Deployment Runtime Policy Audit

**Date:** 2026-07-17
**Status:** Implemented and validated
**Policy under review:**

> Prefer a suitable native NixOS deployment. When two implementations are
> operationally equivalent, native wins. Use a pinned container when it is the
> better-supported or lower-maintenance deployment.

## Executive Decision

The policy is sound and the current deployments broadly follow it. This audit
found no active service that should be migrated between native and container
runtimes immediately.

Three services have real native alternatives but are correctly deployed as
containers today:

- **Plex:** The container is required for the working VA-API userspace while
  the native package has a documented glibc mismatch.
- **Mealie:** The deployed container is 3.20.1. Nixpkgs 25.11 provides 3.9.2
  and unstable provides 3.12.0, so the native alternative is not operationally
  equivalent yet.
- **UniFi:** The container is a proven, self-contained 10.0.162 deployment.
  Nixpkgs 25.11 provides 9.5.21, and moving to the native service would also
  move ownership of the bundled database/JRE lifecycle into this repository.

The actionable findings are not backend migrations. They are:

1. Pin four effective OCI images by digest.
2. Enforce pinning against evaluated host configuration.
3. Record why each container is preferred and when to revisit it.
4. Replace the absolute wording in ADR-005 with the suitability-gated policy
   above.

## Implementation Outcome

The recommended architecture was implemented on 2026-07-17:

- All 38 effective OCI units are digest-pinned, and a flake check validates
  final merged image values for every NixOS configuration.
- Renovate now updates digests for `latest` channels instead of exempting them.
- ADR-005 uses the suitability-gated native policy and records Plex, Mealie, and
  UniFi revisit conditions.
- Service categories have one registry; NAS-0 and NAS-1 use explicit selective
  loading; the orphan selector was removed.
- Optional Attic-to-Caddy, PostgreSQL-to-Grafana, and Alertmanager-to-Grafana
  contributions no longer require their target categories to be imported.
- Stale PostgreSQL collision comments were removed because database option
  ownership is already consolidated in the PostgreSQL module.
- The container factory uses `operationalProfile`, distinct from service import
  categories.
- Runtime-neutral capability fragments and internal runtime facts were proven
  across Actual, Sonarr, and Cooklang without changing their evaluated behavior.
- Fish now lives in an isolated, automatically imported feature that publishes
  NixOS, Darwin, and Home Manager modules through `flake.modules`.

Validation evidence:

- `nix flake check --no-build --all-systems` passes.
- The full Forge closure builds successfully and retains its pre-composition
  system store path.
- Actual/Sonarr and Cooklang focused before/after projections are byte-identical.
- Forge and Darwin Fish projections are byte-identical.
- All NixOS and Darwin system derivation paths are byte-identical before and
  after the Fish move.
- Warm `ciSystems` evaluation changed from 2.37s to 2.44s, which is not a
  material regression.

The full `rymac` Darwin closure now builds successfully. Unstable ld64 957.1
previously trapped in `ld::passes::stubs::Pass::process` while linking Starship
1.26.0 and Lima 2.1.4 on macOS 26.5. Darwin-only package overrides retain those
application versions but select stable Nix ld64 for their builds; Starship's
1,228 tests and Lima's codesign, version check, and template validation pass.
The workaround and removal test are tracked in `docs/workarounds.md`.

Expected evaluation warnings are now:

- Two deprecated `system` accesses originating outside the changed modules.
- Unknown custom flake outputs for `modules`, `allCaddyDnsRecords`, and
  `ciSystems`. The `modules` output is published intentionally by the
  flake-parts named-module registry.

## Method

Seven parallel reviews covered the functional service cohorts, host-only
deployments, and cross-cutting factory/pinning behavior. Focused follow-up
reviews investigated Mealie, UniFi, uncovered host services, and every effective
OCI image without a digest.

Subagent findings were treated as hypotheses. They were reconciled using:

- Effective `nixosConfigurations.*.config`, not source defaults.
- Live NixOS 25.11 and unstable option/package data.
- The pinned repository source and matching host configuration.
- Authoritative Podman and OCI content-addressing documentation.

This distinction mattered. Static reviews incorrectly reported several factory
defaults as deployed images and produced false native candidates for EMQX and
Omada. Effective evaluation corrected those results.

## Repository Structure and Composition Review

The deployment-runtime audit sits inside a broader repository-structure review.
The following findings must be resolved or consciously accepted before adding a
second, top-level module system.

### Structural Findings

1. **Medium: service-category composition has multiple sources of truth.** The
  category map exists in [the system builder](../../lib/mkSystem.nix), the
  all-category import list exists in
  [the category index](../../modules/nixos/services/_categories/default.nix),
  and selected categories are repeated by hosts in [flake.nix](../../flake.nix).
  A fourth implementation,
  [selector.nix](../../modules/nixos/services/_categories/selector.nix), is
  orphaned. Category additions and removals can therefore drift.
2. **Medium: Forge's root import list has reached an ergonomic limit.**
  [Forge's root module](../../hosts/forge/default.nix) contains 93 explicit
  imports, including 71 service files. The list is tedious to maintain, but it
  is also a useful manifest of what Forge runs. Automatic discovery must retain
  equivalent activation visibility.
3. **Medium: a PostgreSQL option-namespace collision remains unresolved.**
  [The base NixOS module](../../modules/nixos/base.nix) comments out the
  database interface because it and the PostgreSQL module define incompatible
  shapes under `modules.services.postgresql`. Resolve this before introducing
  deferred-module merging under another module layer.
4. **Low: NAS-0 and NAS-1 still use the legacy all-services path.** They do not
  pass `serviceCategories` to `mkNixosSystem`, so they evaluate the entire
  service tree. Give both hosts explicit categories before using evaluation
  performance as evidence for or against Dendritic.
5. **Low: all systems evaluate, but the baseline is not warning-free.** The
  current warnings include intentional root ownership for Valhalla without the
  corresponding `rootOwnedReason`, two deprecated `system` accesses that may
  come from inputs, and expected warnings for custom flake outputs. Establish a
  known-warning baseline before measuring a composition pilot.
6. **Validation coverage is strong but asymmetric.** Light NixOS hosts receive
  pull-request closure builds, while Forge and Luna receive pull-request
  evaluation plus scheduled closure builds. Darwin is not built in CI. See
  [the per-PR build workflow](../../.github/workflows/nix-build.yml) and
  [the heavy-host health workflow](../../.github/workflows/flake-health.yml).

### Strengths to Preserve

The repository has coherent architecture rather than accidental complexity:

- [The system builder](../../lib/mkSystem.nix) centralizes NixOS and Darwin
  construction with nested Home Manager.
- Reusable service modules define typed contracts, while host modules own image
  pins, storage protection, backups, alerts, proxying, and dashboards. Sonarr's
  [service module](../../modules/nixos/services/sonarr/default.nix) and
  [Forge deployment](../../hosts/forge/services/sonarr.nix) are representative.
- The queryable `modules.services.*` namespace enables cross-service discovery
  and is deliberately preserved by
  [ADR-011](../adr/011-service-factory-module-architecture.md).
- The contributory infrastructure model keeps service requirements close to
  their owners; see
  [ADR-001](../adr/001-contributory-infrastructure-pattern.md).
- `specialArgs` is already limited to `inputs`, `hostname`, and `mylib` for
  NixOS. Dendritic would not eliminate a serious dependency-injection problem.
- ADRs, formatting, linting, backup-policy checks, and protection-manifest
  checks provide a strong validation base.

Any new composition model must preserve these properties rather than treating
the current repository as a conventional host-centric configuration.

### Dendritic Fit

| Dendritic idea | Fit in this repository |
| --- | --- |
| Feature-first organization | Already substantially present in Forge service files and contributory modules. |
| Automatic imports | Useful for category and import maintenance if activation remains explicit. |
| Cross-class deferred modules | Useful for the smaller shell, Nix, and security surface spanning NixOS, Darwin, and Home Manager. |
| Eliminating `specialArgs` | Limited benefit because the current injected surface is already small. |
| Avoiding `enable` options | Conflicts with the valuable queryable service registry. Do not apply this guidance to services. |
| Every file as a top-level module | Poor wholesale fit because libraries, packages, overlays, disk constructors, and generated expressions need exceptions. |
| File-path independence | Mixed benefit because current paths communicate ownership and module class. |

### Dendritic Decision

Dendritic is worth exploring, but the repository should not migrate wholesale.
The ranked options are:

1. Run a scoped true-Dendritic pilot after local composition repairs and after
  the service-contract work has settled.
2. Borrow only automatic import and flake-parts modularization where they solve
  a measured maintenance problem.
3. Retain the current architecture unchanged if the pilot does not improve
  ownership or composition.
4. Reject a wholesale conversion of every Nix file.

The unique benefit to test is co-locating one feature's NixOS, Darwin, and Home
Manager contributions. Removing import lists alone does not justify a second
module system.

### Dendritic Preconditions

Before the composition pilot:

1. Consolidate the category registry into one source of truth.
2. Delete or wire the orphan category selector.
3. Give NAS-0 and NAS-1 explicit service categories.
4. Resolve the PostgreSQL option-namespace collision.
5. Establish the expected evaluation-warning baseline.
6. Complete or explicitly abandon the service-contract pilot so runtime and
  composition changes cannot obscure each other's failures.

### Scoped Dendritic Pilot

Use one isolated, automatically imported subtree rather than scanning the
repository root. Pilot Fish because its behavior already spans:

- NixOS and Darwin system shell configuration.
- Home Manager Fish configuration.
- Per-host login-shell choices, which must remain explicit because Forge uses
  Bash for VS Code Remote SSH while other hosts use Fish directly.

Those cross-class contributions and their helper scripts now live together in
[the Fish feature](../../features/shell/fish.nix).

The pilot must leave `modules.services.*`, `mylib`, service factories, host
service files, and contributory option paths unchanged.

It succeeds only when:

1. Relevant derivation paths and evaluated configuration remain identical.
2. `nix flake check --no-build --all-systems` passes.
3. Representative NixOS builds and a local Darwin build pass.
4. Failure traces remain understandable and identify the owning feature.
5. Evaluation time does not materially regress.
6. Moving or splitting the feature no longer requires import-list maintenance.

Revert the pilot if it changes the service registry, obscures which features a
host enables, requires broad root-level auto-import exceptions, or introduces
more composition machinery than it removes.

### Research Basis

The composition recommendation is based on direct source and ADR review,
repository counts, all-system evaluation, current upstream documentation,
adopter repositories, an independent migration report, and an adversarial
pro/con model review.

Primary references:

- [The Dendritic pattern](https://github.com/mightyiam/dendritic)
- [The author's reference infrastructure](https://github.com/mightyiam/infra)
- [Independent migration report](https://not-a-number.io/2025/refactoring-my-infrastructure-as-code-configurations/)

The independent migration found real feature-oriented composition benefits but
described adoption as slow and occasionally painful. That supports a reversible
pilot rather than a repository rewrite.

## Coverage

### Typed Service Registry

The evaluated configurations contain **69 unique enabled service registry
entries** and **90 host/service assignments**.

| Configuration | Enabled registry entries |
| --- | ---: |
| forge | 62 |
| luna | 9 |
| nas-0 | 0 |
| nas-1 | 3 |
| nixos-bootstrap | 0 |
| nixpi | 6 |
| nixpi-image | 6 |
| rydev | 4 |

`nixpi-image` is a build form of `nixpi`, not a separate production runtime.
Host-owned services outside `modules.services.*` were reviewed separately,
including CoachIQ, Grocy, homelab-mcp, Marginalia, Music Assistant, pgBackRest,
Redis, RepLog, UPS/NUT and PeaNUT, Valhalla, Whiskey, and Qui auto-recheck.

### OCI Runtime

Effective evaluation found **38 OCI units** across two hosts:

| Host | OCI units |
| --- | ---: |
| forge | 35 |
| luna | 3 |

These units represent 33 logical deployments because Grafana OnCall, Netvisor,
and 1Password Connect each use multiple containers.

The logical OCI deployments reviewed were:

- Apprise, Autobrr, Bazarr, Bichon, Dispatcharr, EMQX, Enclosed, ESPHome,
  Grafana OnCall, IT-Tools, Mealie, Netvisor, Omada, Plex, Prowlarr,
  qBittorrent, Qui, Radarr, SABnzbd, Scrypted, Seerr, Sonarr, Tdarr, Termix,
  TeslaMate, Tracearr, Tududi, Unpackerr, and Valhalla.
- The Music Assistant bgutil provider and PeaNUT dashboard sidecars.
- 1Password Connect and UniFi on Luna.

Scheduled and helper workloads such as Kometa, Recyclarr, pgBackRest, and
Qui auto-recheck were reviewed even when they do not appear as persistent OCI
units.

## Runtime Policy Results

### Native NixOS or Upstream Modules

The native choice remains appropriate for the following deployed services:

- Actual, AdGuard Home, Caddy, Chrony, Gatus, GitHub Runner, go2rtc, Grafana,
  Grocy, Home Assistant, Homepage, Loki, Miniflux, Music Assistant,
  Node Exporter, OpenSSH, Paperless, Pinchflat, PostgreSQL, Prometheus,
  Alertmanager, Promtail, Redis, Resilio Sync, SearXNG, Tautulli, The Lounge,
  NUT, Zigbee2MQTT, and Z-Wave JS UI.
- CoachIQ, homelab-mcp, Marginalia, RepLog, and Whiskey use native NixOS modules
  supplied by their flake inputs and locked by `flake.lock`.

These services benefit from NixOS/systemd integration without a material
version or feature penalty.

### Custom Native Services

Custom systemd remains lower-maintenance than introducing containers for the
following deployed services and helpers:

- Attic and Attic administration, backup orchestration, cfdyndns, Cloudflared,
  Cooklang, Cooklang Federation, Glances, GPU metrics, pgBackRest, Pgweb,
  Pocket ID, Qui auto-recheck, and World Monitor.

These are generally simple packaged processes, local automation, or integrations
whose systemd and credential behavior is intentionally owned by this repository.

### Justified Containers

The active container deployments are justified by one or more of the following:

- No suitable NixOS module or package exists.
- Upstream's supported deployment and migration path is the container image.
- The dependency or plugin ecosystem is substantially lower-maintenance in the
  upstream image.
- A specific userspace is required for hardware support.
- A native module exists but is not operationally equivalent at the deployed
  version and feature set.

No deployed container failed that suitability test.

## Native Candidates Reviewed

### Mealie: Keep Container, Revisit on Version Parity

The native module is real and reasonably shaped: it supports settings,
credentials, PostgreSQL, an address, and a port. Infrastructure integrations
such as ZFS, backup, proxying, and preseed could be retained in a native wrapper;
their absence from the upstream module is not itself a reason to reject native.

The current blocker is package parity:

| Source | Version |
| --- | --- |
| Forge OCI deployment | 3.20.1 |
| Nixpkgs 25.11 | 3.9.2 |
| Nixpkgs unstable | 3.12.0 |

The deployed configuration also uses OIDC group mapping, PostgreSQL with
`pg_trgm`, SMTP, and AI functionality. Keep the digest-pinned container until
the native package is close enough to test those requirements without a
downgrade. Revisit when the version gap is small and a backup/restore rehearsal
can be performed.

Evidence: [Forge Mealie configuration](../../hosts/forge/services/mealie.nix)
and [Mealie service module](../../modules/nixos/services/mealie/default.nix).

### UniFi: Keep Container, Revisit Only with a Planned Data Migration

The native `services.unifi` module exists, but the alternatives are not
currently operationally equivalent:

| Source | Version |
| --- | --- |
| Luna OCI deployment | 10.0.162 |
| Nixpkgs 25.11 | 9.5.21 |
| Nixpkgs unstable | 10.1.89 |

Using unstable could close the application-version gap, but migration would
also change MongoDB/JRE ownership and the tested data-layout path. The current
container is digest-pinned, backed up, and operationally proven. Keep it until
there is a concrete benefit that justifies a database migration and device
adoption test window.

Evidence: [UniFi module](../../modules/nixos/services/unifi/default.nix).

### Plex: Keep Container Until the Native Hardware Issue Is Resolved

Plex intentionally supports both runtimes. Forge selects the digest-pinned
container because hardware transcoding is affected by a native userspace/glibc
compatibility issue. This is a documented exception, not a general model for
making every service runtime-selectable.

Evidence: [Plex module](../../modules/nixos/services/plex/default.nix).

### False-Positive Native Candidates

Live option searches found no NixOS service module for EMQX or Omada in either
25.11 or unstable, and no 25.11 service module for 1Password Connect or
Apprise. Their container/custom choices remain appropriate.

## Image Reproducibility

### Effective Pin Status

Of 38 effective OCI units, **34 are digest-pinned**. Four are not:

| Host | Unit | Effective image | Action |
| --- | --- | --- | --- |
| forge | grafana-oncall-redis | `redis:7.4-alpine` | Use a fully qualified version and digest. |
| forge | scrypted | `ghcr.io/koush/scrypted:latest` | Pin the supported channel to a digest. |
| forge | tracearr | `ghcr.io/connorgallopo/tracearr:latest` | Prefer a release tag and digest. |
| forge | valhalla | `ghcr.io/valhalla/valhalla-scripted:latest` | Prefer a release tag and digest. |

Relevant sources:

- [Grafana OnCall module](../../modules/nixos/services/grafana-oncall/default.nix)
- [Scrypted module](../../modules/nixos/services/scrypted/default.nix)
- [Tracearr host configuration](../../hosts/forge/services/tracearr.nix)
- [Valhalla host configuration](../../hosts/forge/services/valhalla.nix)

### Correct Digest Semantics

An image reference ending in `@sha256:<digest>` is content-addressed. The digest
identifies and verifies the selected OCI content even when the human-readable tag
is `latest`. Therefore Tududi's `latest@sha256:...` reference is reproducible,
although a versioned tag would communicate intent more clearly.

Podman's `newer` pull policy compares digests. It may add a registry lookup or
pull the explicitly requested digest, but it cannot silently substitute content
that does not match an explicit digest. Treat `--pull=newer` as an availability
and startup-latency consideration for pinned references, not as a mechanism that
defeats content addressing.

Authoritative references:

- [Podman pull policy](https://docs.podman.io/en/latest/markdown/podman-pull.1.html#policy-policy)
- [OCI content descriptors](https://github.com/opencontainers/image-spec/blob/main/descriptor.md#digests)

### Renovate Gap

[Renovate configuration](../../.github/renovate.json5) explicitly disables
digest pinning when the current tag is `latest`. This prevents automated
remediation for Scrypted, Tracearr, and Valhalla.

Preferred policy:

1. Use `version@sha256` whenever upstream publishes meaningful release tags.
2. Use `latest@sha256` only when upstream exposes no usable immutable release
   channel.
3. Allow Renovate to update digests for both forms.

## Service Factory Structural Findings

### Factory Defaults Are Not Deployment Policy

Factory-based modules commonly use `latest` as a reusable default, but every
active factory deployment evaluated on Forge currently resolves to a digest-pinned
host override. Source-grep checks would therefore produce false failures.

Pin validation must inspect effective enabled host configuration. The factory
should still fail enabled deployments whose final `cfg.image` lacks a digest so
future hosts cannot accidentally inherit a mutable default.

### Runtime Rationale Is Not Machine-Readable

Container justifications are scattered across comments and workaround docs.
A minimal internal deployment record should eventually capture:

```nix
deployment = {
  kind = "oci"; # nixos-module | upstream-module | custom-systemd | oci
  rationale = "Upstream-supported image; no suitable NixOS module";
  nativeCandidate = null;
  lastReviewed = "2026-07-17";
  revisitWhen = "A feature-complete NixOS module becomes available";
};
```

This metadata should describe decisions, not select the runtime. Runtime choice
should normally remain fixed by the service module; Plex-like dual backends are
exceptions.

### Common Contract, Separate Runtime Adapters

The audit reinforces the proposed architecture:

- Preserve one typed `modules.services.<name>` registry.
- Extract composable integration capabilities for web endpoints, state,
  backup, recovery, observability, and notifications.
- Keep nixpkgs-module, custom-systemd, and OCI implementations distinct.
- Do not reintroduce a universal native-service factory.

The existing container factory's `category` controls operational defaults such
as NFS behavior, alert channels, and tags. It should eventually be renamed to
`operationalProfile` so it is not confused with service import categories.

### What the Factory Review Changes

The current container factory combines three different abstractions:

1. **Homelab service contract:** enablement, reverse proxy, metrics, logging,
   backup, notifications, and recovery.
2. **OCI runtime mechanics:** image, timezone, resources, health checks,
   volumes, user mapping, Podman networks, and extra ports.
3. **Operational profile defaults:** media/download NFS behavior, shared groups,
   alert channels, labels, and backup tags.

Only the first abstraction should be shared across all runtimes. OCI mechanics
must remain in the container adapter, and operational profiles must be opt-in
policy inputs rather than options added to every service. The current factory
declares media and download options for non-media services to keep one uniform
shape; a capability model should remove that pressure.

`mkNativeServiceOptions` was exported but had no consumers. This was useful
evidence: native wrappers share infrastructure capabilities, but their upstream
module semantics differ too much for a universal native factory. The validated
pilot replaced it with composable option fragments and removed the unused
helper.

## Proposed Target Architecture

### Design Goals

The service architecture should provide:

- One stable, typed, queryable registry at `modules.services.<name>`.
- The same infrastructure vocabulary for native, custom-systemd, and OCI
  services where the capability is meaningful.
- Runtime-specific behavior that remains obvious and debuggable in the owning
  service module.
- Host-owned deployment policy: enablement, version or image pin, domains,
  resource budgets, storage protection objectives, and backup policy.
- No requirement for a service to expose options for capabilities it does not
  have.

### Layer Responsibilities

| Layer | Responsibility | Examples |
| --- | --- | --- |
| Capability fragments | Declare reusable, runtime-neutral options | web endpoint, metrics, logging, backup, notifications, recovery |
| Runtime adapter | Produce the actual process and runtime facts | `services.actual`, custom `systemd.services`, Podman container |
| Service module | Own application semantics and connect capabilities to the adapter | OIDC settings, database requirements, volumes, migrations |
| Host module | Instantiate policy for one host | image/package pin, hostname, ZFS protection, resources, alert severity |
| Infrastructure aggregators | Consume service contributions | Caddy, Restic, Sanoid, Prometheus, Alertmanager, Homepage |

This extends rather than replaces the two-layer decision in ADR-011. The
reusable service module remains the registry and implementation owner; the host
module remains the deployment-policy owner.

### Capability Fragments

Start with small fragments whose duplication is already proven. Provisional
names are illustrative, not a committed API:

```nix
mylib.serviceOptions = {
  base = { name, description }: { /* enable and internal metadata */ };
  web = { defaultPort, ... }: { /* port and reverseProxy */ };
  observable = { serviceType, ... }: { /* metrics, logging, notifications */ };
  stateful = { defaultDataDir, ... }: { /* dataDir and backup */ };
  recoverable = { ... }: { /* preseed/restore policy */ };
};
```

Rules for these fragments:

- A service composes only the capabilities it has.
- Fragments declare options and defaults; they do not choose a runtime.
- Media/NFS options are a separate opt-in fragment, never part of `base`.
- Application-specific options stay beside the application implementation.
- Shared fragments must not depend on Podman, an upstream NixOS module, or a
  particular systemd unit name.

### Runtime Facts

Integrations need a small amount of information that differs by backend. Each
service adapter should publish internal, read-only runtime facts rather than
making infrastructure infer them from naming conventions:

```nix
_runtime = {
  kind = "oci"; # nixos-module | upstream-module | custom-systemd | oci
  units = [ "podman-sonarr.service" ];
  endpoints.web = {
    scheme = "http";
    host = "127.0.0.1";
    port = 8989;
  };
  identity = {
    user = "sonarr";
    group = "media";
  };
  statePaths = [ "/var/lib/sonarr" ];
};
```

The exact option path should be finalized during the pilot. It must be internal,
typed, and generated by the service module. Host configurations should not set
runtime facts directly.

### Runtime Adapters

Use three explicit implementation paths:

1. **NixOS/upstream module wrapper**
   - Configure `services.<name>` or an imported upstream module.
   - Preserve upstream package, user, state-directory, and credential semantics
     unless a host requirement demands an override.
2. **Custom systemd service**
   - Use when a packaged single process is straightforward and owning the unit
     is lower-maintenance than an image supply chain.
   - Own `ExecStart`, credentials, users, state directories, and hardening.
3. **OCI container adapter**
   - Own image, digest validation, volumes, user mapping, networks, health
     checks, and Podman-specific dependencies.
   - Continue using the existing factory for conventional single-container
     services while its runtime-neutral pieces are extracted incrementally.
   - Require explicit persistent-state mounts, non-root execution where the
     image supports it, health checks, independently reviewed image updates,
     and vulnerability tracking.

An OCI container is a packaging and process-isolation mechanism, not a hard
security boundary. Use a VM or microVM when the requirement is strong isolation
from the host kernel rather than deployment convenience.

Do not add a universal `deploymentMode` option. A service normally selects one
implementation in its module. A dual backend is permitted only for:

- A temporary, reversible migration.
- An unresolved upstream incompatibility such as Plex hardware acceleration.
- A host capability that genuinely changes the correct backend.

Every dual backend doubles important test paths and needs an explicit review
condition for removing one path.

### Runtime Decision Sequence

For each new or reconsidered service:

1. **Suitable nixpkgs module?** Use it when version, required features, secrets,
   state, migrations, hardware, and upstream support are operationally
  equivalent, and when doing so does not require extensive overrides of the
  upstream module's user, state, or lifecycle assumptions.
2. **Suitable upstream NixOS module?** Treat a flake-supplied module as native
   when it is maintained with the application and integrates cleanly.
3. **Simple packaged process?** Prefer a custom systemd service when the package
   exists and the unit/configuration surface is small and stable.
4. **Container lower-maintenance or better-supported?** Use an OCI image when
   upstream owns that deployment path, packaging is complex, a specific
  userspace is required, native parity is materially behind, or owning the
  native packaging and update cadence would cost more than operating the image
  supply chain.

Native wins a tie; it does not win merely by existing. Record the deciding
constraint and a concrete revisit condition for every container exception.

### Explicit Non-Goals

- Do not convert existing justified containers solely to improve a native
  percentage.
- Do not hide Podman and systemd differences behind a single implementation
  function.
- Do not duplicate every upstream NixOS option in the homelab namespace.
- Do not move host protection objectives or version pins into reusable service
  modules.
- Do not combine this refactor with service-category, Dendritic, or broad host
  import rewrites.
- Do not create capability flags that are used by only one service.

## Recommended Work

### P0: Reproducibility (Completed 2026-07-17)

1. Pin the four effective OCI references listed above.
2. Remove the Renovate exemption that disables digest pinning for `latest`.
3. Add an evaluation check over every `nixosConfiguration` that rejects enabled
   OCI units without `@sha256:<64 lowercase hex characters>`.

The check should evaluate final container values rather than grep source files.

### P1: Policy and Decision Records (Completed 2026-07-17)

1. Amend [ADR-005](../adr/005-native-services-over-containers.md) to use the
   suitability-gated policy at the top of this report.
2. Document Mealie, UniFi, and Plex as reviewed container exceptions with
   explicit revisit conditions.
3. Define when a dual runtime option is permitted: temporary migration,
   unresolved upstream incompatibility, or a host capability that genuinely
   changes the correct backend.
4. Add internal deployment metadata only after its type and ownership are
  proven by the service-contract pilot.

### P2: Service Contract Pilot (Completed 2026-07-17)

#### Phase A: Capture Baselines

Record focused evaluated configuration for Actual and Sonarr across these
surfaces:

- Their `modules.services.*` options.
- Native service or OCI container configuration.
- Caddy contributions.
- Storage, backup, alerting, and preseed contributions.
- Relevant systemd dependencies and service users.

Also record evaluation time for Forge and the closure paths of the affected
services. The objective is regression detection, not a performance target.

#### Phase B: Extract Option Fragments

1. Introduce only the capability fragments needed by both Actual and Sonarr.
2. Convert option declarations without changing generated configuration.
3. Leave runtime implementation blocks untouched in this phase.

This establishes whether the common vocabulary is useful before introducing a
shared integration renderer.

#### Phase C: Publish Runtime Facts

1. Have Actual publish native unit, endpoint, identity, and state facts.
2. Have Sonarr publish OCI unit, endpoint, identity, and state facts.
3. Convert one low-risk integration, preferably Caddy registration or failure
  notification wiring, to consume those facts.
4. Stop if the helper needs backend-specific branches beyond the supplied facts.

#### Phase D: Add a Custom-Systemd Service

Add Cooklang only after Actual and Sonarr pass all gates. This tests the third
runtime path without growing the first experiment's scope.

#### Phase E: Decide, Document, or Revert

After all three adapters are represented:

- Keep and document fragments that reduce real duplication.
- Leave service-specific integration code local when abstraction adds branches.
- Keep `mkNativeServiceOptions` removed; the fragments replace its intended
  runtime-neutral role without hiding native implementation semantics.
- Update ADR-011 only after the evaluated design proves stable.

### Pilot Acceptance Gates

The service-contract pilot succeeds only when all of the following hold:

1. **Public compatibility:** Existing host-facing option paths and defaults are
  unchanged.
2. **Registry compatibility:** Cross-service checks continue to use the same
  `modules.services.<name>.enable` namespace.
3. **Behavioral equivalence:** Focused evaluated output for services, containers,
  Caddy, storage, backup, alerts, users, and systemd dependencies is unchanged
  except for intentional internal metadata.
4. **Runtime clarity:** A maintainer can identify the owning backend and unit
  without tracing through a universal dispatcher.
5. **Capability discipline:** Neither service receives irrelevant media,
  container, database, or recovery options.
6. **No branch migration:** Common helpers consume runtime facts and do not
  contain growing `if native then ... else ...` logic.
7. **Validation:** `nix flake check --no-build --all-systems` passes, followed by
  the repository's Forge build task before merge.
8. **Reversibility:** Each phase is independently revertible and does not mix
  service behavior changes with structural changes.

### Pilot Stop Conditions

Stop and retain the existing architecture if any of these occur:

- The common contract becomes a union of every backend's options.
- A second service needs exceptions to a newly extracted helper.
- Host files lose ownership of pins, resources, or protection objectives.
- Service modules become harder to understand without reading factory internals.
- Evaluation errors become less local or option traces become materially worse.
- The change reduces lines while increasing conceptual layers or hidden control
  flow.

### P3: Local Composition Repairs (Completed 2026-07-17)

1. Consolidate category definitions and selection validation.
2. Remove or integrate the orphan selector module.
3. Move NAS-0 and NAS-1 to explicit service categories.
4. Resolve the PostgreSQL option collision before introducing deferred modules.
5. Document or remove the known evaluation warnings.

These repairs improve the existing architecture independently of Dendritic and
make the composition experiment easier to evaluate.

### P4: Composition Experiment (Completed 2026-07-17)

Run any Dendritic experiment separately on a small cross-class feature. Do not
combine module-composition and runtime-contract migrations in one change. Use
the Fish scope and gates in [Scoped Dendritic Pilot](#scoped-dendritic-pilot).

## Suggested Pull Request Sequence

Keep the work bisectable and avoid mixing policy, behavior, and architecture:

1. **OCI reproducibility:** Pin four images, fix Renovate policy, and add the
  effective-image evaluation check.
2. **Policy wording:** Amend ADR-005 and document the three reviewed container
  exceptions.
3. **Category composition:** Establish one category registry, remove or wire
  the selector, and assign explicit NAS categories.
4. **PostgreSQL namespace:** Resolve the database-interface option collision in
  an isolated change.
5. **Terminology:** Rename factory `category` to `operationalProfile` in a
  mechanical, behavior-preserving change.
6. **Capability declarations:** Add fragments and convert Actual/Sonarr option
  declarations only.
7. **Runtime facts:** Publish facts and migrate one shared integration.
8. **Third adapter:** Add Cooklang to the proven contract.
9. **Architecture decision:** Update ADR-011, remove the unused native helper,
  and decide whether broader adoption is justified.
10. **Composition pilot:** Evaluate the isolated Fish feature on NixOS and
   Darwin after the service-contract work settles.

## Re-Audit Triggers

Repeat the focused suitability review when any of the following occurs:

- A previously absent NixOS service module appears.
- A native package reaches feature/version parity with a container exception.
- A documented native blocker is fixed.
- A service changes database, plugin, hardware, or supported deployment model.
- An OCI image loses digest pinning or changes publisher.
- A wrapper accumulates substantial `mkForce` or backend-specific workarounds.

A full repository audit is useful annually or before a major architecture
rewrite. Routine pull requests should rely on effective-configuration checks and
focused reviews of changed services.
