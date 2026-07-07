<h1 align="center">📚 Custom Library</h1>

<p align="center">
  <em>Reusable helper functions injected as <code>mylib</code></em>
</p>

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Available Helpers](#-available-helpers)
- [Usage Pattern](#-usage-pattern)
- [Adding New Helpers](#-adding-new-helpers)

---

## 🔍 Overview

This directory contains custom library functions that are injected into the NixOS module system as `mylib`. These helpers reduce boilerplate and ensure consistency across host and service configurations.

### How It Works

The library is aggregated in `default.nix` and made available through `specialArgs`:

```nix
# In flake.nix or similar
specialArgs = {
  mylib = import ./lib { inherit lib; };
};

# In any module
{ config, lib, mylib, ... }:
```

---

## 🛠️ Available Helpers

### `types.nix` / `types/`

Shared submodule types for standardized service options (`metricsSubmodule`, `loggingSubmodule`, `backupSubmodule`, `reverseProxySubmodule`, ...).

```nix
someOption = lib.mkOption {
  type = mylib.types.metricsSubmodule;
};
```

### `service-factory.nix`

Helm-like module generator for container services. `mylib.mkContainerService` generates a complete service module (options, container definition, user/group, ZFS dataset, Caddy vhost registration, Gatus endpoint contribution, container hardening defaults, backup/preseed wiring) from a concise spec. Also exports `mkNativeServiceOptions` and `categoryDefaults`. See the header comment in the file for full documentation.

### `dns.nix`

DNS record generators for internal and external zones.

```nix
mylib.dns.mkARecord {
  name = "forge";
  ip = "10.20.0.30";
}
```

### `dns-aggregate.nix`

Aggregates DNS records across multiple sources into unified zone files.

### `monitoring-helpers.nix`

Prometheus alert rule generators for consistent monitoring. Exports `mkThresholdAlert`, `mkDatabaseConnectionsAlert`, `mkHighCapacityAlert`, and `mkContainerDownAlert`.

```nix
modules.alerting.rules."myapp-unhealthy" =
  mylib.monitoring-helpers.mkThresholdAlert {
    name = "myapp";
    alertname = "MyAppUnhealthy";
    expr = ''myapp_healthy == 0'';
    summary = "MyApp unhealthy on {{ $labels.instance }}";
    description = "MyApp health metric reports unhealthy.";
  };
```

Host-oriented alert generators (`mkServiceDownAlert`, `mkSystemdServiceDownAlert`, ...) live in `host-defaults.nix` and are consumed via `forgeDefaults`, not `mylib.monitoring-helpers`.

### `service-uids.nix`

Centralized static UID/GID registry for service accounts (`mylib.serviceUids`) — keeps ownership consistent across ZFS datasets, containers, and NFS shares.

### `host-defaults.nix`

Per-host defaults library. Imported directly by each host (e.g. `hosts/forge/lib/defaults.nix` wraps it as `forgeDefaults`) with host-specific pool names and backup repositories; provides helpers like `mkPreseed`, `mkSanoidDataset`, and `mkServiceDownAlert`. Forge's wrapper additionally exposes the podman bridge gateway IPs (`podmanBridgeGateway`, `podmanDefaultBridgeGateway`) and `pocketidHostsEntry`.

### `mkSystem.nix`

Flake-level system builder — imported directly by `flake.nix`, not exposed through `mylib`.

### `storageHelpers`

Bridge to `modules/nixos/storage/helpers-lib.nix` (takes `pkgs`):

```nix
let storageHelpers = mylib.storageHelpers pkgs;
# mkPreseedService, mkReplicationConfig, mkNfsMountConfig, ...
```

---

## 📖 Usage Pattern

### In NixOS Modules

```nix
{ config, lib, mylib, ... }:

let
  cfg = config.modules.services.myapp;
in
{
  config = lib.mkIf cfg.enable {
    # Use mylib helpers
    modules.alerting.rules."myapp-unhealthy" =
      mylib.monitoring-helpers.mkThresholdAlert {
        name = "myapp";
        alertname = "MyAppUnhealthy";
        expr = ''myapp_healthy == 0'';
        summary = "MyApp unhealthy";
        description = "MyApp health metric reports unhealthy.";
      };

    # Reverse proxy: register directly with the Caddy module
    # (factory-generated services get this automatically via reverseProxy)
    modules.services.caddy.virtualHosts.myapp = {
      enable = true;
      hostName = "myapp.holthome.net";
      backend.port = cfg.port;
    };
  };
}
```

### In Host Configurations

```nix
{ config, lib, mylib, ... }:

{
  # Manual restic job in the unified backup system
  modules.services.backup.restic.jobs.critical-data = {
    repository = "nas-primary";
    paths = [ "/persist/important" ];
    tags = [ "critical" "daily" ];
  };
}
```

---

## ➕ Adding New Helpers

### 1. Create Helper File

```nix
# lib/my-helpers.nix
{ lib }:

{
  myHelper = { arg1, arg2 ? "default" }: {
    # Helper implementation
    result = "${arg1}-${arg2}";
  };

  anotherHelper = value: lib.strings.toUpper value;
}
```

### 2. Register in Aggregator

```nix
# lib/default.nix
{ lib }:

{
  types = import ./types.nix { inherit lib; };
  dns = import ./dns.nix { inherit lib; };
  monitoring-helpers = import ./monitoring-helpers.nix { inherit lib; };
  # ...

  # Add your new helper
  myhelpers = import ./my-helpers.nix { inherit lib; };
}
```

### 3. Use in Modules

```nix
{ mylib, ... }:

{
  something = mylib.myhelpers.myHelper { arg1 = "value"; };
}
```

---

## 📁 Directory Structure

```
lib/
├── default.nix            # Aggregator (exports all helpers as mylib)
├── types.nix              # Shared type definitions (entry point)
├── types/                 # Submodule type implementations
├── service-factory.nix    # Container service module generator
├── host-defaults.nix      # Per-host defaults library (forgeDefaults, ...)
├── mkSystem.nix           # Flake system builder (used by flake.nix)
├── dns.nix                # DNS record generators
├── dns-aggregate.nix      # Zone file aggregation
├── service-uids.nix       # Static UID/GID registry
└── monitoring-helpers.nix # Prometheus alert templates
```

---

## 💡 Design Principles

1. **Consistency** — Helpers enforce naming conventions and structure
2. **Composability** — Small, focused functions that combine well
3. **Type Safety** — Use `lib.types` for option validation where applicable
4. **Documentation** — Each helper should have clear parameter documentation

> [!TIP]
> When adding new infrastructure patterns, consider whether a library helper would reduce duplication across multiple services.
