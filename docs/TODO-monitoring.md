# Monitoring & Alerting TODO

## High Priority

### AlertManager Deployment
**Status**: Not yet deployed
**Priority**: High
**Complexity**: Medium

**Why we need it**:
- Currently exporting Prometheus metrics but no active alerting
- pgBackRest metrics (spool backlog, archive failures) need alerts
- ZFS snapshot health metrics need alerts
- Backup job failures need active notification

**Required Alerts for PostgreSQL**:
1. **pgBackRest Spool Backlog**
   - Alert when `/var/lib/pgbackrest/spool` > 10GB
   - Indicates NFS mount issues or replication lag
   - Severity: High (database may be at risk)

2. **pgBackRest Archive Failures**
   - Alert on `archive_command` failure rate > 0
   - Severity: Critical (PITR capability compromised)

3. **pgBackRest Stale Spool**
   - Alert when oldest file in spool > 30 minutes
   - Indicates NAS unavailability or network issues
   - Severity: High

4. **PostgreSQL WAL Directory Growth**
   - Alert when `pg_wal` directory > 5GB
   - Indicates archiving not keeping up
   - Severity: Critical (disk space risk)

5. **Backup Job Failures**
   - Alert on systemd service failures for backup jobs
   - Severity: High

6. **NFS Mount Health**
   - Alert when `/mnt/nas-backup` not mounted
   - Alert on I/O errors to NFS mount
   - Severity: High

**Integration with Existing**:
- Pushover notifications already configured
- Can route AlertManager → Pushover
- Use existing notification templates

**Implementation Steps**:
1. Add AlertManager to monitoring stack
2. Configure Prometheus to send alerts to AlertManager
3. Set up AlertManager → Pushover integration
4. Define alert rules (see above)
5. Test alert delivery
6. Document runbooks for each alert

**References**:
- Existing Pushover config: `hosts/forge/default.nix` lines 223-234
- pgBackRest metrics: `hosts/forge/default.nix` lines 661-789
- ZFS snapshot metrics: `hosts/forge/default.nix` lines 593-659

## Medium Priority

### Grafana Dashboard for pgBackRest
- Visualize backup success/failure over time
- Show spool queue depth trends
- Display RPO/RTO metrics
- WAL archive lag visualization

### Backup Verification Monitoring
- Track restore test success/failure
- Monitor backup integrity checks
- Alert on verification failures

## Low Priority

### Capacity Planning Alerts
- Predict when disk will be full based on growth trends
- Alert before backup retention causes space issues
- Monitor database growth rate

## Notes
- Current monitoring exports metrics but has no active alerting
- Metrics already being collected (Prometheus node_exporter)
- Just need AlertManager + alert rule definitions
- Pushover integration already exists for notifications
