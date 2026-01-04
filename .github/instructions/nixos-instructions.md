---
applyTo:
  - "**/hosts/**/*.nix"
  - "**/modules/**/*.nix"
  - "**/default.nix"
---

# NixOS Module Development Instructions
**Version 2.1 | Updated: 2026-01-03**

## Recent Changes

- 2026-01-03: Added centralized `mylib.serviceUids` requirement for all UID/GID assignments.
- 2025-11-20: Added doc links, forge contribution example, and Taskfile-focused workflow reminders.

These instructions apply specifically to NixOS configuration files in this homelab repository.

---

## Repository Architecture

### Reference Host: forge

The canonical example of our three-tier architecture (see [`hosts/forge/README.md`](../../hosts/forge/README.md)):

**Tier 1 - Core**: Base system, users, SSH, networking
**Tier 2 - Infrastructure**: Storage (ZFS), backups, monitoring, reverse proxy
**Tier 3 - Services**: Applications (media, automation, etc.)

### Contribution Pattern

Services must co-locate their integration assets (see [`docs/modular-design-patterns.md`](../../docs/modular-design-patterns.md) for full rationale):

```text
modules/services/myservice/
├── default.nix          # Main module
├── alerts/              # Prometheus alerts
├── backup/              # Backup configuration
├── storage/             # Storage requirements
└── monitoring/          # Grafana dashboards
```

**This pattern ensures:**

- Single source of truth for each service
- Automatic infrastructure registration
- Easy discovery and maintenance

---

## Discovery Commands

Before creating a new module, explore existing patterns:

```bash
# Find how storage is declared
rg "modules.storage.datasets" --type nix

# Find backup patterns
rg "modules.backup" --type nix

# Find alert patterns
fd alerts --type d | head -10

# Find reverse proxy configurations
rg "reverseProxy.enable" --type nix

# Find metric exporters
rg "metrics.enable" --type nix
```

---

## Module Development Workflow

### 1. Study Existing Patterns

**Always review these first:**

- [`docs/modular-design-patterns.md`](../../docs/modular-design-patterns.md) – Standardized submodules & shared types
- [`docs/persistence-quick-reference.md`](../../docs/persistence-quick-reference.md) – Impermanence convention
- [`hosts/forge/README.md`](../../hosts/forge/README.md) – Architecture, alert placement, discovery tips
- `modules/services/sonarr/`, `modules/services/radarr/`, `modules/services/scrypted/` – Real modules with full integrations

### 2. Choose Implementation Approach

#### Preference: Native over Container

Use native systemd service when:

- Service is in nixpkgs
- No complex runtime dependencies
- Want hardware access (GPU, storage)
- Need tight integration with system

Use container only when:

- Not in nixpkgs and complex to package
- Multiple tightly-coupled services
- Upstream only provides containers
- Isolation is critical

**Document your reasoning in comments.**

### 3. Standard Submodules

Every service module should support:

```nix
services.myservice = {
  enable = mkEnableOption "myservice";

  # Standard integration points
  reverseProxy = {
    enable = mkEnableOption "reverse proxy";
    domain = mkOption { ... };
  };

  metrics = {
    enable = mkEnableOption "Prometheus metrics";
    port = mkOption { ... };
  };

  backup = {
    enable = mkEnableOption "automated backups";
    paths = mkOption { ... };
  };

  logging = {
    enable = mkEnableOption "centralized logging";
  };

  notifications = {
    enable = mkEnableOption "status notifications";
  };
};
```

### 4. Directory Structure

```nix
# In your module's config section
systemd.tmpfiles.rules = [
  "d /var/lib/myservice 0750 myservice myservice -"
  "d /var/log/myservice 0750 myservice myservice -"
];

# Persistence (if using impermanence)
environment.persistence."/persist" = {
  directories = [
    {
      directory = "/var/lib/myservice";
      user = "myservice";
      group = "myservice";
      mode = "0750";
    }
  ];
};
```

### 5. User/Group Management

**CRITICAL: Use centralized service-uids registry for all UIDs/GIDs.**

The `lib/service-uids.nix` registry ensures:
- Stable UIDs across rebuilds (ZFS ownership consistency)
- Correct container PUID/PGID mappings
- NFS share compatibility
- Backup permission preservation

```nix
{ lib, mylib, ... }:
let
  # Import from centralized registry
  serviceIds = mylib.serviceUids.myservice;
in
{
  users.users.myservice = {
    uid = serviceIds.uid;
    isSystemUser = true;
    group = serviceIds.groupName or "myservice";
    home = "/var/lib/myservice";
    # Use centralized extraGroups (media, render, dialout, etc.)
    extraGroups = serviceIds.extraGroups;
  };

  users.groups.myservice.gid = serviceIds.gid;
}
```

**When adding a new service:**
1. Add entry to `lib/service-uids.nix` with uid, gid, description, extraGroups
2. Use `mylib.serviceUids.servicename` in your module
3. For shared media access, use `gid = mylib.serviceUids.mediaGroup.gid`

**Available shared groups** (from `mylib.serviceUids.sharedGroups`):
- `media` (65537) - arr stack, Plex, download clients
- `render` (303) - GPU hardware transcoding
- `dialout` (27) - USB/serial devices (zigbee, zwave)
- `node-exporter` (989) - Prometheus textfile metrics

### 6. Service Definition

**Systemd service template:**

```nix
systemd.services.myservice = {
  description = "MyService - Brief description";
  after = [ "network-online.target" ];
  wants = [ "network-online.target" ];
  wantedBy = [ "multi-user.target" ];

  serviceConfig = {
    Type = "simple";
    User = "myservice";
    Group = "myservice";

    # Least privilege
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadWritePaths = [ "/var/lib/myservice" ];

    # Startup
    ExecStart = "${pkgs.myservice}/bin/myservice --config /var/lib/myservice/config.yml";

    # Restart behavior
    Restart = "on-failure";
    RestartSec = "10s";
  };
};
```

### 7. Auto-Registration

**Enable automatic infrastructure integration:**

```nix
# Reverse proxy
services.caddy.virtualHosts."myservice.${config.networking.domain}" = mkIf cfg.reverseProxy.enable {
  extraConfig = ''
    reverse_proxy localhost:${toString cfg.port}
  '';
};

# Metrics
services.prometheus.scrapeConfigs = mkIf cfg.metrics.enable [{
  job_name = "myservice";
  static_configs = [{
    targets = [ "localhost:${toString cfg.metrics.port}" ];
  }];
}];

# Backups
services.restic.backups.myservice = mkIf cfg.backup.enable {
  paths = cfg.backup.paths;
  # ... other backup config
};
```

---

## Common Patterns

### Environment Variables

```nix
systemd.services.myservice.environment = {
  HOME = "/var/lib/myservice";
  DATA_DIR = "/var/lib/myservice/data";
};
```

### Configuration Files

```nix
environment.etc."myservice/config.yml".text = ''
  port: ${toString cfg.port}
  data_dir: /var/lib/myservice/data
'';
```

### Networking/Ports

```nix
networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
```

### Dependencies Between Services

```nix
systemd.services.myservice = {
  after = [ "postgresql.service" ];
  requires = [ "postgresql.service" ];
};
```

---

## Temporary Workarounds & Overrides

When packages have bugs, test failures, or missing features in stable nixpkgs, use these patterns:

### Using Unstable Packages

```nix
# When stable version is missing features or has bugs
package = mkOption {
  type = types.package;
  default = pkgs.unstable.myservice;  # Use unstable
  defaultText = lib.literalExpression "pkgs.unstable.myservice";
  description = "Package to use. Using unstable for [reason].";
};
```

### Package Overrides (in overlays/default.nix)

```nix
# WORKAROUND (2025-12-19): Test failures with Python 3.13
# Affects: home-assistant (depends on this package)
# Upstream: https://github.com/example/issue/123
# Check: When package is updated in nixpkgs
mypackage = prev.mypackage.overridePythonAttrs (old: {
  doCheck = false;  # or disabledTestPaths
});
```

### Module-Level Workarounds

```nix
# WORKAROUND (2025-12-19): Upstream OIDC bug missing parameter
# See: https://github.com/upstream/issues/456
extraConfig = ''
  # Fix upstream bug by injecting missing parameter
  rewrite @missing_param {path}?{query}&param=value
'';
```

### Documentation Requirements

1. **Always add inline comment** with:
   - Date added (`WORKAROUND (YYYY-MM-DD):`)
   - Brief explanation
   - Upstream issue link (if exists)
   - Condition to check for removal

2. **Add entry to `docs/workarounds.md`** for tracking

3. **Review periodically** - workarounds should be removed when upstream fixes land

See [`docs/workarounds.md`](../../docs/workarounds.md) for the complete tracking list.

---

## Forge Contribution Example

Real module demonstrating the contribution pattern (`hosts/forge/services/cooklang-federation.nix`):

```nix
modules.services.cooklangFederation = {
  enable = true;
  reverseProxy = {
    enable = true;
    hostName = "fedcook.holthome.net";
  };
  backup.enable = true;
  preseed = {
    enable = true;
    repositoryUrl = "r2:forge-backups/cooklang-federation";
    passwordFile = config.sops.secrets."restic/password".path;
  };
  notifications.enable = true;
};

modules.storage.datasets.services."cooklang-federation" = {
  mountpoint = "/data/cooklang-federation";
  recordsize = "16K";
  owner = config.modules.services.cooklangFederation.user;
  group = config.modules.services.cooklangFederation.group;
};

modules.backup.sanoid.datasets."tank/services/cooklang-federation" = {
  useTemplate = [ "services" ];
  recursive = false;
  replication.targetDataset = "backup/forge/zfs-recv/cooklang-federation";
};

modules.alerting.rules."cooklang-federation-service-down" = {
  type = "promql";
  expr = "systemd_unit_state{name=\"cooklang-federation.service\",state=\"active\"} == 0";
  severity = "high";
};
```

Use this as a template when wiring new services: declare the service, storage dataset, backup policy, replication target, and alert in the same file.

## Deployment Workflow

### Test Locally

```bash
nix flake check
task nix:build-<host>
```

### Apply Changes

```bash
task nix:apply-nixos host=<host> NIXOS_DOMAIN=holthome.net
```

### Rollback if Needed

Use the host's bootloader generation selector or, if you must run a raw command during incident response:

```bash
nixos-rebuild --rollback switch --flake .#<host>
```

List available automation targets anytime with `task --list`.

---

## Anti-Patterns to Avoid

### ❌ Don't: Hardcode domains

```nix
domain = "myservice.example.com";
```

### ✅ Do: Use dynamic domains

```nix
domain = "myservice.${config.networking.domain}";
```


### ❌ Don't: Run as root

```nix
User = "root";
```

### ✅ Do: Use dedicated user

```nix
User = "myservice";
Group = "myservice";
```


### ❌ Don't: Skip security hardening

```nix
ExecStart = "${pkgs.myservice}/bin/myservice";
```

### ✅ Do: Apply systemd hardening

```nix
serviceConfig = {
  NoNewPrivileges = true;
  PrivateTmp = true;
  ProtectSystem = "strict";
  # ... more hardening
};
```


### ❌ Don't: Manual integration

```nix
# Manually add to reverse proxy elsewhere
# Manually configure backup elsewhere
```

### ✅ Do: Auto-registration via submodules

```nix
services.myservice = {
  enable = true;
  reverseProxy.enable = true;
  backup.enable = true;
};
```

---

## Quality Checklist

Before considering a module complete:

- [ ] Follows three-tier architecture (placed in correct tier)
- [ ] Uses contribution pattern (co-located assets)
- [ ] Native over container (or justified why container)
- [ ] Dedicated user/group with least privilege
- [ ] Systemd hardening applied
- [ ] Standard submodules implemented (reverseProxy, metrics, backup)
- [ ] Auto-registers with infrastructure
- [ ] Persistence configured correctly
- [ ] Discovery commands work (`rg` finds it appropriately)
- [ ] Mirrors existing patterns (sonarr, radarr)
- [ ] Host integration example provided
- [ ] Can be understood by another maintainer in 5 minutes
- [ ] Any workarounds documented in `docs/workarounds.md`

---

## Examples to Study

**Complete service modules:**

- `modules/services/sonarr/default.nix` - Media service with full integration
- `modules/services/radarr/default.nix` - Similar pattern
- `modules/services/scrypted/default.nix` - Container-based service
- `modules/services/dispatcharr/default.nix` - Simple service

**Host configuration:**

- `hosts/forge/services/` - Service declarations
- `hosts/forge/README.md` - Architecture documentation
- `hosts/forge/core/` - Base system configuration

**Infrastructure modules:**

- `modules/storage/` - Storage management
- `modules/backup/` - Backup system
- `modules/monitoring/` - Monitoring setup

---

**Remember: Study existing modules before creating new ones. When in doubt, follow the forge pattern and reference the docs linked above.**
