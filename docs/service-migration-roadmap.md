# Service Migration Roadmap

This document outlines the phased approach to migrate all service modules to follow the standardized modular design patterns established in [modular-design-patterns.md](./modular-design-patterns.md).

## Current State Analysis

### Service Compliance Audit

| Service Module          | Compliance Level      | Analysis & Missing Patterns                                                                                                                                                                                                                                                                                                                           |
| ----------------------- | --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Core Patterns**       |                       |                                                                                                                                                                                                                                                                                                                                                       |
| `caddy`                 | **Compliant**         | **Reference Implementation.** Defines the `reverseProxy` pattern. Its `virtualHosts` structure is the model for how other services should declare their web-facing endpoints.                                                                                                                                                                          |
| `postgresql`            | **Compliant**         | **Reference Implementation.** Defines the pattern for stateful resource provisioning. Its structured `databases` and `permissionsPolicy` options are exemplary. Lacks a metrics submodule, which is an opportunity for enhancement.                                                                                                                   |
| `observability`         | **Partially Compliant** | Bundles the monitoring stack effectively but **lacks the central config generators** for Prometheus/Promtail. This is the module where the auto-discovery logic needs to be built.                                                                                                                                                                   |
| **Infrastructure**      |                       |                                                                                                                                                                                                                                                                                                                                                       |
| `glances`               | **Partially Compliant** | **Present**: Good `reverseProxy` integration. **Missing**: A formal `metrics` submodule. The metrics endpoint is enabled, but it's not discoverable by Prometheus automatically.                                                                                                                                                                      |
| `node-exporter`         | **Partially Compliant** | Similar to Glances. It exists solely to provide metrics but does not auto-register itself with Prometheus. A prime candidate for the `metrics` submodule.                                                                                                                                                                                          |
| `blocky`, `bind`, `dnsdist` | **Non-Compliant**       | Core network services. These are likely simple wrappers around the base NixOS modules. **Missing**: `metrics`, `logging`, and `reverseProxy` (for UIs) submodules. High value targets for monitoring integration.                                                                                                                                      |
| `openssh`, `chrony`     | **Non-Compliant**       | Basic system services. While they don't need all patterns (like reverse proxy), they would benefit from standardized `logging` and potentially `metrics` where applicable (e.g., connection stats).                                                                                                                                                      |
| **Containerized Apps**  |                       |                                                                                                                                                                                                                                                                                                                                                       |
| `dispatcharr`           | **Partially Compliant** | A feature-rich but monolithic module. **Present**: Has its own internal logic for reverse proxy, database, backups, and notifications. **Missing**: Uses bespoke, non-reusable patterns instead of the standardized submodules we've designed. It's the perfect candidate for refactoring to *consume* the new shared patterns, which will significantly simplify its code. |
| `onepassword-connect`   | **Partially Compliant** | A simpler container service. **Present**: Basic container configuration (image, volumes). **Missing**: Integration with `reverseProxy`, `metrics`, `logging`, and `backup`. Lacks standardized resource management.                                                                                                                                     |
| `sonarr`, `adguardhome` | **Non-Compliant**       | Presumably similar to `dispatcharr` or `onepassword-connect` but without the files, I assess them as non-compliant. They likely contain duplicated boilerplate for container setup, reverse proxying, etc.                                                                                                                                            |
| `omada`, `unifi`        | **Non-Compliant**       | Network controller software, likely complex container deployments. **Missing**: All standardized patterns. These would benefit greatly from the `container`, `reverseProxy`, `backup`, and `metrics` submodules.                                                                                                                                        |
| **Legacy/Other**        |                       |                                                                                                                                                                                                                                                                                                                                                       |
| `nginx`, `haproxy`      | **Non-Compliant**       | Legacy reverse proxies. They do not follow the Caddy auto-generation pattern and represent technical debt if Caddy is the go-forward standard.                                                                                                                                                                                                        |

## Migration Strategy

### Phase 1: Build Foundational Abstractions (PRIORITY)

**Goal**: Create reusable building blocks that enable all other standardization work.

#### 1.1 Develop the `metrics` Submodule & Generator (Week 1-2)

**Implementation Plan**:
1. Create `lib/types.nix` with standardized submodule definitions
2. Implement Prometheus scrape config generator in `observability/default.nix`
3. Add collection mechanism to scan all services for `metrics` submodules

**Key Components**:
```nix
# lib/types.nix
metricsSubmodule = types.submodule {
  options = {
    enable = mkEnableOption "Prometheus metrics collection";
    port = mkOption { type = types.port; };
    path = mkOption { type = types.str; default = "/metrics"; };
    scrapeInterval = mkOption { type = types.str; default = "60s"; };
    labels = mkOption { type = types.attrsOf types.str; default = {}; };
  };
};
```

**Expected Outcome**: Services can declare `metrics.enable = true` and automatically appear in Prometheus configuration.

#### 1.2 Develop Standard `container` Submodule (Week 2-3)

**Implementation Plan**:
1. Create reusable container configuration helper in `lib/container.nix`
2. Standardize resource management, security hardening, and health checks
3. Integrate with existing `podmanLib` helpers

**Key Features**:
- Unified resource limits (memory, CPU)
- Standardized security settings
- Health check integration
- Volume and environment management

#### 1.3 Develop `logging` Submodule & Generator (Week 3-4)

**Implementation Plan**:
1. Design logging submodule for file-based and journald logs
2. Implement Promtail configuration generator
3. Add log parsing and labeling support

**Expected Outcome**: Services automatically ship logs to Loki without manual Promtail configuration.

### Phase 2: Refactor Core Infrastructure (Week 5-8)

**Goal**: Apply new patterns to foundational services and prove the approach.

#### 2.1 Migrate Simple Monitoring Services

**Services**: `node-exporter`, `glances`
**Timeline**: Week 5

**Actions**:
- Add `metrics` submodule to both services
- Remove manual firewall configurations
- Test auto-discovery with Prometheus

**Success Criteria**:
- Prometheus automatically discovers both services
- No manual configuration required
- Services properly labeled in monitoring

#### 2.2 Migrate Core Network Services

**Services**: `blocky`, `bind`, `dnsdist`
**Timeline**: Week 6-7

**Actions**:
- Add `metrics` and `logging` submodules
- Add `reverseProxy` for services with web interfaces
- Ensure all network services are monitored

**Success Criteria**:
- Complete visibility into network infrastructure
- Automatic log aggregation
- Web interfaces accessible via Caddy

#### 2.3 Enhance `observability` Module

**Timeline**: Week 8

**Actions**:
- Implement automatic scrape config generation
- Add log source discovery for Promtail
- Create health check dashboards

### Phase 3: Refactor Complex Applications (Week 9-16)

**Goal**: Apply patterns to complex containerized services.

#### 3.1 Refactor `dispatcharr` (Week 9-12)

**Priority**: High - This is the template for all other containerized services

**Actions**:
1. Replace container boilerplate with standard `container` submodule
2. Migrate to standard `reverseProxy` submodule
3. Add `metrics` and `logging` submodules
4. Standardize `backup` and `notifications` patterns
5. Implement `database.consumer` pattern

**Expected Outcome**:
- 50% reduction in module complexity
- Reusable patterns for other services
- Improved maintainability

#### 3.2 Migrate Application Services (Week 13-16)

**Services**: `sonarr`, `onepassword-connect`, `omada`, `unifi`, `adguardhome`

**Actions**:
- Apply `dispatcharr` refactor patterns
- Standardize all container configurations
- Add monitoring and backup integration

### Phase 4: Clean Up & Validation (Week 17-20)

#### 4.1 Remove Legacy Services

**Services**: `nginx`, `haproxy` (if not needed)

**Actions**:
- Audit usage of legacy reverse proxies
- Migrate remaining functionality to Caddy
- Remove unused modules

#### 4.2 Validation & Testing

**Actions**:
- Create integration tests for auto-registration
- Add module validation tests
- Document troubleshooting guides
- Performance testing of generated configurations

## Implementation Guidelines

### Code Quality Standards

1. **Type Safety**: All new submodules must use proper `types.submodule` definitions
2. **Documentation**: Every option requires clear descriptions and examples
3. **Validation**: Use assertions to catch configuration errors early
4. **Security**: Default to secure configurations with explicit overrides

### Testing Strategy

1. **Unit Tests**: Validate submodule option processing
2. **Integration Tests**: Test auto-registration functionality
3. **End-to-End Tests**: Verify monitoring and logging pipelines
4. **Performance Tests**: Ensure configuration generation scales

### Breaking Change Management

1. **Deprecation Warnings**: Add warnings for legacy options
2. **Migration Guides**: Document upgrade paths for each service
3. **Backward Compatibility**: Maintain legacy support during transition
4. **Release Notes**: Document all breaking changes

## Success Metrics

### Technical Metrics

- **Code Reduction**: Target 30-50% reduction in service module size
- **Configuration Drift**: Eliminate manual Prometheus/Promtail configuration
- **Time to Deploy**: Reduce new service deployment time by 60%
- **Maintenance Burden**: Reduce service-specific configuration by 80%

### Operational Metrics

- **Monitoring Coverage**: 100% of services have metrics and logging
- **Alert Response**: All services have standardized failure notifications
- **Backup Coverage**: All stateful services have automated backups
- **Security Posture**: All containers use standardized hardening

## Risk Mitigation

### High-Risk Changes

1. **Dispatcharr Refactor**: Critical service with complex dependencies
   - **Mitigation**: Thorough testing in development environment
   - **Rollback Plan**: Keep legacy configuration alongside new implementation

2. **Prometheus Config Changes**: Could break existing monitoring
   - **Mitigation**: Implement feature flags for new auto-discovery
   - **Rollback Plan**: Maintain manual configuration as fallback

3. **Container Standardization**: Risk of breaking working services
   - **Mitigation**: Incremental migration with validation at each step
   - **Rollback Plan**: Pin container configurations during migration

### Timeline Risks

- **Scope Creep**: Focus on standardization, not feature additions
- **Resource Constraints**: Prioritize high-impact, low-risk changes first
- **Testing Bottlenecks**: Implement automated testing early in process

## Resources Required

### Development Time

- **Phase 1**: 4 weeks (foundational work)
- **Phase 2**: 4 weeks (core infrastructure)
- **Phase 3**: 8 weeks (complex applications)
- **Phase 4**: 4 weeks (cleanup & validation)
- **Total**: 20 weeks (5 months)

### Validation Environment

- Dedicated testing infrastructure
- Monitoring stack for validation
- Automated testing pipeline

This roadmap provides a systematic approach to achieving service module standardization while minimizing risk and maintaining operational stability.
