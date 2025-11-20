---
applyTo: "**/*"
---

# Security & Compliance Instructions

**Version:** 2.0 | Updated: 2025-11-20

## Recent Changes

- 2025-11-20: Linked core docs, aligned validations with Taskfile workflow, clarified documentation references.

These security requirements apply to ALL files in this repository.

---

## Absolute Prohibitions

### ❌ NEVER: Inline secrets

```nix
# WRONG - secret in plaintext
services.myservice.apiKey = "<plaintext-secret>";

# WRONG - secret in attribute
password = "mypassword123";

# WRONG - secret in environment
environment = {
  API_KEY = "secret-key-here";
};
```

### ❌ NEVER: Commit unencrypted credentials

```bash
# WRONG - unencrypted secrets file
secrets.yaml  # Plain text

# WRONG - .env files with secrets
.env
.env.local
```

### ❌ NEVER: Bypass SOPS

```nix
# WRONG - manual secret management
environment.etc."myservice/secret".text = "my-secret";
```

### ❌ NEVER: Public security groups

```hcl
# WRONG - open to world
ingress {
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}
```

### ❌ NEVER: Skip validation

```bash
# WRONG - applying without checking
nixos-rebuild switch

# WRONG - pushing without testing
git push
```

---

## Required: Secret Management with SOPS

### All secrets MUST use SOPS

**Correct pattern:**

```nix
# Reference encrypted secret
sops.secrets.myservice-api-key = {
  sopsFile = ./secrets.yaml;
  owner = "myservice";
  group = "myservice";
  mode = "0400";
};

# Use in service
systemd.services.myservice = {
  serviceConfig = {
    EnvironmentFile = config.sops.secrets.myservice-api-key.path;
  };
};
```

**Editing secrets:**

```bash
# Edit encrypted file (requires GPG key)
sops secrets/production.yaml

# Add new secret
sops --set '["myservice"]["api_key"] "new-value"' secrets/production.yaml
```

**Creating new secrets file:**

```bash
# Initialize with your GPG key
sops --age <age-public-key> secrets/new-host.yaml
```

### Secret File Organization

```text
secrets/
├── common.yaml          # Shared secrets
├── forge.yaml           # Host-specific
└── production.yaml      # Environment-specific
```

---

## Required: Validation Before Changes

### Pre-commit Validation

**Before ANY pull request:**

```bash
# 1. Build check
nix flake check

# 2. Build specific host
task nix:build-<host>  # or relevant host

# 3. Dry run
nixos-rebuild dry-build --flake .#<host>

# 4. If Terraform present
terraform plan
terraform validate
```

### Continuous Validation

**If using Terraform:**

```bash
# Static analysis
tflint

# Security scanning
checkov -d .
tfsec .
```

**NixOS specific:**

```bash
# Check for evaluation errors
nix flake check

# Validate host builds
task nix:build-<host>
```

---

## Required: Least Privilege

### Service Users

Every service MUST run as dedicated non-root user:

```nix
# ✅ Correct
users.users.myservice = {
  isSystemUser = true;
  group = "myservice";
  home = "/var/lib/myservice";
};

systemd.services.myservice.serviceConfig = {
  User = "myservice";
  Group = "myservice";
};

# ❌ Wrong
systemd.services.myservice.serviceConfig = {
  User = "root";  # Never do this
};
```

### File Permissions

```nix
# ✅ Correct - restrictive permissions
systemd.tmpfiles.rules = [
  "d /var/lib/myservice 0750 myservice myservice -"
  "f /var/lib/myservice/secret 0400 myservice myservice -"
];

# ❌ Wrong - too permissive
systemd.tmpfiles.rules = [
  "d /var/lib/myservice 0777 root root -"  # Never 777
];
```

### Network Exposure

```nix
# ✅ Correct - explicit firewall rules
networking.firewall.interfaces."eth0".allowedTCPPorts = [ cfg.port ];

# ✅ Correct - conditional opening
networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];

# ❌ Wrong - unconditionally open
networking.firewall.allowedTCPPorts = [ 80 443 8080 9090 ];
```

---

## Required: Systemd Hardening

### Minimum Hardening Requirements

Every systemd service MUST include:

```nix
systemd.services.myservice.serviceConfig = {
  # Privilege escalation
  NoNewPrivileges = true;

  # Filesystem isolation
  PrivateTmp = true;
  ProtectSystem = "strict";
  ProtectHome = true;

  # Only allow writes where needed
  ReadWritePaths = [ "/var/lib/myservice" ];

  # Process isolation
  PrivateDevices = true;  # If no device access needed

  # Network isolation (if applicable)
  PrivateNetwork = false;  # Set true if no network needed

  # Kernel restrictions
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectControlGroups = true;
};
```

### Additional Hardening (when applicable)

```nix
serviceConfig = {
  # Capabilities (drop all, add only what's needed)
  CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
  AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];

  # System calls
  SystemCallFilter = [ "@system-service" "~@privileged" ];
  SystemCallArchitectures = "native";

  # Restrict address families
  RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];

  # Resource limits
  LimitNOFILE = 65536;
  MemoryMax = "2G";
  TasksMax = 512;
};
```

---

## Required: Backup Verification

### All stateful services MUST have backup configuration

```nix
# In module
services.myservice.backup = {
  enable = mkEnableOption "automated backups";
  paths = mkOption {
    type = types.listOf types.str;
    default = [ "/var/lib/myservice" ];
  };
};

# In implementation
services.restic.backups.myservice = mkIf cfg.backup.enable {
  paths = cfg.backup.paths;
  repository = "b2:backup-bucket";
  # ... rest of config
};
```

### Backup Testing

```bash
# Verify backup job exists
systemctl list-timers | grep restic

# Test backup
systemctl start restic-backups-myservice.service

# Verify backup contents
restic -r <repository> snapshots
restic -r <repository> ls latest
```

---

## Required: Audit Trail

### Configuration Changes

All infrastructure changes MUST be:

- Tracked in git
- Associated with a clear commit message
- Reviewed before deployment

```bash
# Good commit messages
git commit -m "feat(forge): add jellyfin service with reverse proxy"
git commit -m "fix(security): harden nginx systemd service"
git commit -m "chore(secrets): rotate API keys for monitoring"

# Bad commit messages
git commit -m "update"
git commit -m "fix"
git commit -m "changes"
```

### Access Logging

Services with sensitive data MUST enable access logging:

```nix
services.myservice = {
  logging = {
    enable = true;
    level = "info";
    destination = "/var/log/myservice/access.log";
  };
};
```

---

## Required: Compliance References

### Documentation to Review

Before implementing security-sensitive changes, review:

- **Backup policies**: [`docs/backup-system-onboarding.md`](../../docs/backup-system-onboarding.md)
- **Monitoring requirements**: [`docs/monitoring-strategy.md`](../../docs/monitoring-strategy.md)
- **Secret management & notifications**: [`docs/notifications.md`](../../docs/notifications.md) (Pushover flows, escalation), [`docs/operational-safety-improvements.md`](../../docs/operational-safety-improvements.md)
- **Network segmentation & architecture**: [`hosts/forge/README.md`](../../hosts/forge/README.md)
- **Storage & persistence policies**: [`docs/modular-design-patterns.md`](../../docs/modular-design-patterns.md), [`docs/persistence-quick-reference.md`](../../docs/persistence-quick-reference.md)

### External Resources

- OWASP IaC Security Cheat Sheet
- NixOS Security Best Practices: [nixos.org/manual/nixos/stable/#sec-security](https://nixos.org/manual/nixos/stable/#sec-security)
- Systemd Security Directives: `man systemd.exec`
- SOPS Documentation: [github.com/mozilla/sops](https://github.com/mozilla/sops)

---

## Security Checklist

Before merging ANY infrastructure change:

- [ ] No secrets in plaintext
- [ ] All secrets use SOPS encryption
- [ ] Services run as non-root users
- [ ] Systemd hardening applied
- [ ] File permissions restrictive (no 777, no world-readable secrets)
- [ ] Network exposure minimized and explicit
- [ ] Backup configuration present for stateful services
- [ ] Validation commands passed (`nix flake check`)
- [ ] Git commit message clear and descriptive
- [ ] Changes reviewed by another person (if team environment)

---

## Incident Response

### If Secret is Compromised

1. **Immediately rotate the secret**

  ```bash
   sops secrets/production.yaml
   # Update compromised value
   ```

1. **Update all systems**

  ```bash
   task nix:apply-nixos host=forge
   ```

1. **Review access logs**

  ```bash
   journalctl -u myservice.service -S "2 hours ago"
   ```

1. **Document in git**

  ```bash
   git commit -m "security: rotate compromised API key for myservice"
   ```

### If Vulnerability Discovered

1. **Assess impact**
   - What systems are affected?
   - What data is at risk?
   - Is it actively exploited?

1. **Patch immediately**

  ```bash
   # Update package
   nix flake update

   # Apply updates
   task nix:apply-nixos host=forge
   ```

1. **Verify mitigation**

  ```bash
   # Check running version
   systemctl status myservice

   # Verify patch applied
   nix-store -q --references /run/current-system | grep myservice
   ```

1. **Document and notify**

---

## Security Review Triggers

Schedule security review when:

- Adding new service with external exposure
- Changing authentication or authorization
- Modifying secret management
- Updating critical infrastructure (DNS, VPN, reverse proxy)
- After any security incident
- Quarterly (calendar reminder)

---

**Security is not optional. When in doubt, ask for review before deploying.**
