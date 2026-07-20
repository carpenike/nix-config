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

The library is aggregated in `default.nix` and made available through `specialArgs` (see `lib/mkSystem.nix`):

```nix
# In lib/mkSystem.nix
specialArgs = {
  inherit inputs hostname mylib;
};

# In any module
{ config, lib, mylib, ... }:
```

---

## 🛠️ Available Helpers

### `service-factory.nix`

The container service factory (`mkContainerService`) — generates a complete service module (options, container, Caddy vhost, ZFS dataset, user/group, firewall, preseed, notifications) from a concise spec. See ADR-011 and the file's own documentation.

```nix
mylib.mkContainerService {
  name = "sonarr";
  category = "media";
  port = 8989;
  # ...
}
```

### `service-options.nix`

Runtime-neutral service capability option fragments (`mylib.serviceOptions`) — small composable option sets shared by service modules regardless of runtime.

### `types.nix` / `types/`

Shared submodule types (metrics, logging, backup, reverseProxy, healthcheck, protection, …) so factory-based and hand-rolled services expose the same option schema. See ADR-003.

```nix
someOption = lib.mkOption {
  type = mylib.types.metricsSubmodule;
};
```

### `dns.nix`

Shared DNS utilities (subdomain extraction, record formatting) used by the Caddy DNS modules.

### `dns-aggregate.nix`

Fleet-wide DNS aggregation: reads `modules.services.caddy.virtualHosts` from every host and renders zone A-records. Exposed as the `allCaddyDnsRecords` flake output:

```bash
nix eval .#allCaddyDnsRecords --raw
```

### `monitoring-helpers.nix`

Prometheus alert rule generators for consistent monitoring.

```nix
mylib.monitoring-helpers.mkServiceDownAlert {
  job = "myservice";
  severity = "critical";
  for = "2m";
}
```

### `service-uids.nix`

Central static UID/GID registry for all service accounts (`mylib.serviceUids`) — keeps ownership consistent across ZFS datasets, containers, and NFS shares.

### `host-defaults.nix`

Contributory-defaults helper used by host-level `lib/defaults.nix` wrappers (e.g. `hosts/forge/lib/defaults.nix`) to provide per-host presets (podman network, backup, preseed, caddy security). See ADR-002.

### `storageHelpers`

`mylib.storageHelpers pkgs` — ZFS dataset, NFS mount, and preseed service helpers (implemented in `modules/nixos/storage/helpers-lib.nix`).

### `mkSystem.nix`

System builders (`mkNixosSystem`, `mkDarwinSystem`, `mkNixosBootstrapSystem`). Imported directly by `flake.nix`, not part of the `mylib` aggregation.

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
    modules.alerting.rules."myapp-down" =
      mylib.monitoring-helpers.mkServiceDownAlert {
        job = "myapp";
        severity = "high";
      };

    # Register a reverse-proxy vhost directly (see docs/reverse-proxy-pattern.md)
    modules.services.caddy.virtualHosts.myapp = {
      hostName = "myapp.holthome.net";
      proxyTo = "localhost:${toString cfg.port}";
    };
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
{
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
├── mkSystem.nix           # System builders (used directly by flake.nix)
├── service-factory.nix    # Container service factory (mkContainerService)
├── service-options.nix    # Runtime-neutral service capability fragments
├── types.nix              # Shared type aggregator
├── types/                 # Shared submodule types (backup, metrics, …)
├── dns.nix                # DNS record utilities
├── dns-aggregate.nix      # Fleet-wide zone record aggregation
├── monitoring-helpers.nix # Prometheus alert templates
├── service-uids.nix       # Central UID/GID registry
└── host-defaults.nix      # Per-host contributory defaults (ADR-002)
```

---

## 💡 Design Principles

1. **Consistency** — Helpers enforce naming conventions and structure
2. **Composability** — Small, focused functions that combine well
3. **Type Safety** — Use `lib.types` for option validation where applicable
4. **Documentation** — Each helper should have clear parameter documentation

> [!TIP]
> When adding new infrastructure patterns, consider whether a library helper would reduce duplication across multiple services.
