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

### `backup-helpers.nix`

Backup configuration generators for Restic and ZFS.

```nix
mylib.backup-helpers.mkResticJob {
  name = "myservice";
  paths = [ "/var/lib/myservice" ];
  repository = "primary";
}
```

### `caddy-helpers.nix`

Reverse proxy configuration builders for Caddy.

```nix
mylib.caddy-helpers.mkVirtualHost {
  domain = "app.example.com";
  backend = "localhost:8080";
  auth = "pocketid";
}
```

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

### `register-vhost.nix`

Virtual host registration helpers for service discovery.

```nix
mylib.registerVhost {
  name = "grafana";
  port = 3000;
  public = true;
}
```

### `monitoring-helpers.nix`

Prometheus alert rule generators for consistent monitoring.

```nix
mylib.monitoring-helpers.mkServiceDownAlert {
  job = "myservice";
  severity = "critical";
  for = "2m";
}

mylib.monitoring-helpers.mkHighMemoryAlert {
  job = "myservice";
  threshold = 90;
}
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
    modules.alerting.rules."myapp-down" =
      mylib.monitoring-helpers.mkServiceDownAlert {
        job = "myapp";
        severity = "high";
      };

    modules.services.caddy.virtualHosts.myapp =
      mylib.caddy-helpers.mkVirtualHost {
        domain = "myapp.holthome.net";
        backend = "localhost:${toString cfg.port}";
      };
  };
}
```

### In Host Configurations

```nix
{ config, lib, mylib, ... }:

{
  modules.backup.restic.jobs = {
    critical-data = mylib.backup-helpers.mkResticJob {
      name = "critical";
      paths = [ "/persist/important" ];
      tags = [ "critical" "daily" ];
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
{ lib }:

{
  backup = import ./backup-helpers.nix { inherit lib; };
  caddy = import ./caddy-helpers.nix { inherit lib; };
  dns = import ./dns.nix { inherit lib; };
  monitoring = import ./monitoring-helpers.nix { inherit lib; };

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
├── backup-helpers.nix     # Restic/ZFS backup utilities
├── caddy-helpers.nix      # Reverse proxy configuration
├── dns.nix                # DNS record generators
├── dns-aggregate.nix      # Zone file aggregation
├── register-vhost.nix     # Service registration
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
