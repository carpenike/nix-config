# Shared Config Library: Helm-like Patterns for NixOS

**Last Updated**: 2026-01-23

This document describes the service factory pattern in this repository, which provides Helm-like templating for NixOS service modules.

---

## Overview

The service factory (`lib/service-factory.nix`) provides factory functions that dramatically reduce boilerplate when creating service modules. Similar to Helm's `values.yaml` + `_helpers.tpl` pattern:

| Helm Concept | NixOS Equivalent |
|--------------|------------------|
| `values.yaml` | Service `spec` passed to factory |
| `_helpers.tpl` | Factory functions in `lib/service-factory.nix` |
| Chart templates | Generated NixOS module (options + config) |
| `{{- include "mychart.name" . }}` | `mylib.mkContainerService { ... }` |

---

## Current Library Structure

```
lib/
├── default.nix               # Aggregates all helpers into mylib
├── service-factory.nix       # ← NEW: Helm-like service factories
├── types/                    # Shared type definitions
│   ├── metrics.nix
│   ├── logging.nix
│   ├── backup.nix
│   ├── reverse-proxy.nix
│   └── ...
├── host-defaults.nix         # Parameterized host-specific helpers
├── service-uids.nix          # Centralized UID/GID registry
├── monitoring-helpers.nix    # Alert template helpers
├── caddy-helpers.nix         # Reverse proxy helpers
└── storage-helpers.nix       # ZFS/NFS/preseed helpers
```

---

## Service Factory Pattern

### When to Use

Use `mylib.mkContainerService` when your service:
- Runs in a Podman container
- Has a web interface (optional Caddy integration)
- Needs ZFS dataset storage
- Follows standard patterns (backup, metrics, logging)

### Basic Usage

```nix
# modules/nixos/services/myservice/default.nix
{ lib, mylib, pkgs, config, podmanLib, ... }:

mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "myservice";
  description = "My awesome service";

  spec = {
    port = 8080;
    image = "ghcr.io/org/myservice:latest";
    category = "productivity";  # media, infrastructure, home-automation, etc.
  };
}
```

This single call generates:
- ✅ All standard options (enable, dataDir, port, user, group, image, timezone, resources, healthcheck, reverseProxy, metrics, logging, backup, notifications, preseed)
- ✅ Caddy reverse proxy registration
- ✅ ZFS dataset with optimized properties
- ✅ System user creation
- ✅ Container definition with healthchecks
- ✅ Systemd dependencies

### Service Categories

Categories provide sensible defaults:

| Category | `serviceType` | Alert Channel | NFS Mount | Default Group |
|----------|---------------|---------------|-----------|---------------|
| `media` | `media_management` | `media-alerts` | Yes | `media` |
| `downloads` | `downloads` | `media-alerts` | Yes | `media` |
| `productivity` | `productivity` | `system-alerts` | No | Service GID |
| `infrastructure` | `infrastructure` | `system-alerts` | No | Service GID |
| `home-automation` | `home_automation` | `home-alerts` | No | Service GID |
| `monitoring` | `observability` | `system-alerts` | No | Service GID |
| `ai` | `ai` | `system-alerts` | No | Service GID |

### Full Spec Reference

```nix
spec = {
  # Required
  port = 8080;                      # Service port
  image = "org/image:tag";          # Container image

  # Category (determines defaults)
  category = "media";               # See categories table above

  # Display/identification
  description = "Human readable";   # Used in option descriptions
  displayName = "MyService";        # Used in alerts/notifications
  function = "video_streaming";     # Used in Prometheus labels

  # Ports
  containerPort = 8080;             # Internal port if different from `port`

  # Health checks
  healthEndpoint = "/health";       # HTTP endpoint to check (default: "/")
  startPeriod = "120s";             # Time before health checks start

  # Resources
  resources = {
    memory = "512M";
    memoryReservation = "256M";
    cpus = "1.0";
  };

  # ZFS storage tuning
  zfsRecordsize = "16K";            # Optimal for SQLite: "16K", streaming: "1M"
  zfsCompression = "zstd";          # "lz4", "zstd", "off"
  zfsProperties = { };              # Additional ZFS properties

  # Metrics
  metricsPath = "/metrics";         # Prometheus scrape path
  metricsPort = 9090;               # If different from service port

  # Backup
  useZfsSnapshots = true;           # Enable snapshot-based backup
  backupExcludePatterns = [ ];      # Additional patterns to exclude

  # Backend (for reverse proxy)
  backendScheme = "http";           # "http" or "https"

  # Container startup
  runAsRoot = false;                # Default: false. Set true if entrypoint needs root
                                    # (e.g., to chown files before dropping privileges)

  # Container configuration
  environment = { cfg, config, usesExternalAuth }: {
    # Dynamic environment variables
    MY_VAR = "value";
  };

  volumes = cfg: [
    # Additional volumes beyond dataDir
    "${cfg.mediaDir}:/data:rw"
  ];

  extraOptions = { cfg, config }: [
    # Additional podman options
    "--device=/dev/dri:/dev/dri"
  ];

  environmentFiles = [
    # Static environment files
    "/path/to/env"
  ];

  containerOverrides = {
    # Direct overrides to podmanLib.mkContainer
  };
};
```

### Extra Options

Add service-specific options beyond the standard set:

```nix
extraOptions = {
  apiKeyFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = "Path to API key file";
  };

  enableFeatureX = lib.mkEnableOption "feature X";
};
```

### Extra Config

Add service-specific configuration:

```nix
extraConfig = cfg: {
  # Access cfg.apiKeyFile, cfg.enableFeatureX, etc.

  sops.templates."myservice-env" = lib.mkIf (cfg.apiKeyFile != null) {
    content = ''
      API_KEY=${config.sops.placeholder."myservice/api_key"}
    '';
  };

  # Add extra systemd dependencies
  systemd.services.podman-myservice.after = [ "extra-dep.service" ];
};
```

---

## Comparison: Before and After

### Before (Traditional ~450 lines)

```nix
{ lib, mylib, pkgs, config, podmanLib, ... }:
let
  storageHelpers = mylib.storageHelpers pkgs;
  sharedTypes = mylib.types;
  serviceIds = mylib.serviceUids.sonarr;
  cfg = config.modules.services.sonarr;
  # ... 20+ more let bindings ...
in
{
  options.modules.services.sonarr = {
    enable = lib.mkEnableOption "sonarr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sonarr";
      description = "Path to Sonarr data directory";
    };

    # ... 30+ more options, all nearly identical to radarr, lidarr, etc. ...

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Sonarr";
    };

    # ... metrics, logging, backup, notifications, preseed ...
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions = [ ... ];

      modules.services.caddy.virtualHosts.sonarr = lib.mkIf ... { ... };
      modules.storage.datasets.services.sonarr = { ... };
      users.users.sonarr = { ... };

      virtualisation.oci-containers.containers.sonarr = podmanLib.mkContainer "sonarr" {
        # ... 50+ lines of container config ...
      };

      systemd.services."podman-sonarr" = lib.mkMerge [ ... ];
    })
  ];
}
```

### After (Factory Pattern ~80 lines)

```nix
{ lib, mylib, pkgs, config, podmanLib, ... }:

mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "sonarr";
  description = "TV series collection manager";

  spec = {
    port = 8989;
    image = "lscr.io/linuxserver/sonarr:latest";
    category = "media";
    function = "tv_series";
    healthEndpoint = "/ping";
    startPeriod = "300s";
    zfsRecordsize = "16K";
    metricsPath = "/api/v3/health";

    environment = { usesExternalAuth, ... }: {
      SONARR__AUTH__METHOD = if usesExternalAuth then "External" else "None";
    };

    volumes = cfg: [ "${cfg.mediaDir}:/data:rw" ];
  };

  extraOptions = {
    apiKeyFile = lib.mkOption { ... };
  };

  extraConfig = cfg: {
    sops.templates."sonarr-env" = { ... };
  };
}
```

**Reduction: ~80% less boilerplate** while maintaining full flexibility.

---

## Migration Strategy

### Phase 1: Validate Factory (Current)

1. ✅ Create `lib/service-factory.nix`
2. ✅ Add to `lib/default.nix`
3. ✅ Create example in `_examples/`
4. 🔄 Test with `nix flake check`

### Phase 2: Pilot Migration

Migrate one service (e.g., tududi - simpler service):

```bash
# 1. Create backup of original
cp modules/nixos/services/tududi/default.nix modules/nixos/services/tududi/default.nix.bak

# 2. Rewrite using factory
# 3. Test: nix build .#nixosConfigurations.forge.config.system.build.toplevel
# 4. Deploy and verify
```

### Phase 3: Batch Migration

Migrate services by category:
1. **Productivity** (simpler): tududi, privatebin, it-tools
2. **Media stack**: sonarr, radarr, lidarr, readarr, prowlarr, bazarr
3. **Downloads**: qbittorrent, sabnzbd
4. **Complex services**: Last (may need special handling)

### Phase 4: Deprecate Old Patterns

After all migrations:
1. Update `docs/modular-design-patterns.md`
2. Add migration guide
3. Remove duplicated code from individual modules

---

## When NOT to Use the Factory

The factory is optimized for the common case. Don't use it when:

- **Native services** (not containers) - Use `mkNativeServiceOptions` helper instead
- **Multi-container stacks** (e.g., TeslaMate with PostgreSQL) - Manual composition
- **Complex lifecycle** (e.g., pgBackRest with WAL archiving) - Needs custom logic
- **Non-standard patterns** (e.g., StatefulSet-like behavior) - Manual implementation

---

## Troubleshooting

### Container Permission Errors

**Symptom**: Container fails with `chown: Operation not permitted` or similar permission errors during startup.

```
chown: /app/backend/dist/locales/ko/quotes.json: Operation not permitted
```

**Cause**: The factory runs containers with `--user=<uid>:<gid>` by default for security. Some containers (especially those built with LinuxServer.io patterns) have entrypoints that need root to chown files before dropping privileges.

**Solution**: Set `runAsRoot = true` in the service spec:

```nix
spec = {
  # ...
  runAsRoot = true;  # Let container handle privilege dropping
};
```

**Services that need this**: tududi, any container with `chown` or `chmod` in entrypoint scripts.

### Duplicate Mount Destination Error

**Symptom**: Container fails with exit code 125 and error:

```
Error: /data: duplicate mount destination
```

**Cause**: The factory automatically adds `${downloadsDir}:/data` for media/downloads categories. If your `volumes` spec also mounts to `/data`, you get a conflict.

**Solution**: The factory now only adds the default mount when `volumes = null`. If you define custom volumes, you're responsible for all mounts:

```nix
spec = {
  category = "media";
  # Custom volumes override the default downloadsDir:/data mount
  volumes = cfg: [
    "${cfg.mediaDir}:/data:rw"
  ];
};
```

### Missing Directory Error

**Symptom**: Container fails with:

```
Error: statfs /mnt/downloads: no such file or directory
```

**Cause**: The `media` and `downloads` categories set default `downloadsDir = /mnt/downloads` and/or `mediaDir = /mnt/media`. If your host doesn't have these NFS mounts (or the service doesn't need them), the container won't start.

**Solution**: Override the defaults in your host config:

```nix
# hosts/forge/services/prowlarr.nix
{
  config = {
    modules.services.prowlarr = {
      enable = true;
      # Prowlarr is an indexer - it doesn't need media/downloads access
      downloadsDir = null;
      mediaDir = null;
    };
  };
}
```

### Understanding Exit Code 125

Exit code 125 means "container failed to start" (before the entrypoint even runs). Common causes:
- Duplicate volume mounts
- Missing source directories
- Invalid container options

Check `journalctl -u podman-<service>.service` for the full error message.

### Using the Debug Attribute

Every factory-generated module includes a `_debug` attribute:

```bash
nix eval .#nixosConfigurations.forge.config.modules.services.sonarr._debug --json | jq
```

This shows:
- Resolved spec values
- Computed defaults
- Category-specific settings
- Validation status

---

## Migration Lessons Learned

### Lesson 1: Test Each Service Category

Different categories have different defaults. What works for `productivity` may fail for `media` due to:
- NFS mount requirements (`downloadsDir`, `mediaDir`)
- Different user/group membership (`media` group)
- Volume mount patterns

**Best Practice**: Migrate one service per category first, verify it works, then batch migrate the rest.

### Lesson 2: Watch for Entrypoint Assumptions

Many container images assume they start as root and drop privileges themselves. The factory's default of running with `--user` breaks these containers.

**Signs you need `runAsRoot = true`**:
- `chown` or `chmod` in the entrypoint
- `gosu` or `su-exec` in the entrypoint
- LinuxServer.io images with `PUID`/`PGID` environment variables
- Container logs mention permission denied during startup

### Lesson 3: Explicit is Better Than Implicit

The factory provides smart defaults, but services often need explicit overrides:

```nix
# BAD: Hoping defaults work
modules.services.prowlarr.enable = true;

# GOOD: Explicitly declare what the service needs
modules.services.prowlarr = {
  enable = true;
  downloadsDir = null;  # Prowlarr doesn't need downloads
  mediaDir = null;      # Prowlarr doesn't need media
};
```

### Lesson 4: Category Defaults vs Service Reality

Category defaults are educated guesses, not guarantees:

| Category | Default Assumption | But Some Services... |
|----------|-------------------|---------------------|
| `media` | Needs `/data` mount | Only need indexing (prowlarr) |
| `downloads` | Writes to downloads | Only orchestrates (sonarr, radarr) |
| `productivity` | No NFS needed | May share data across network |

**Always verify** what your specific service actually needs.

---

## Related Documentation

- [Modular Design Patterns](./modular-design-patterns.md) - Standardized submodule patterns
- [Repository Architecture](./repository-architecture.md) - High-level structure
- [host-defaults.nix](../lib/host-defaults.nix) - Host-specific factory
- [Monitoring Strategy](./monitoring-strategy.md) - Metrics/alerting patterns
