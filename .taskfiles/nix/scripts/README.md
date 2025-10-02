# DNS Management Scripts

## dns-diff.sh

Smart diff tool for DNS record management that compares generated Caddy DNS records against the current BIND zone file.

### Features

- **Generates DNS records** from all Caddy virtual hosts across the fleet (luna, rydev, nixpi, rymac)
- **Decrypts** SOPS-encrypted zone file automatically
- **Parses** BIND zone format with fallback for systems without `named-checkzone`
- **Shows delta only**: Records to ADD and stale records to review
- **Validates** for duplicate records in generated output
- **Normalizes** whitespace (tabs vs spaces) for accurate comparison

### Usage

```bash
# Via task runner (recommended)
task nix:dns-records

# Or directly
.taskfiles/nix/scripts/dns-diff.sh
```

### Output

The script provides four sections:

1. **Records to ADD** - New Caddy services not yet in zone file (GREEN)
2. **STALE Records** - Records in zone but not generated (YELLOW)
   - May be intentional manual entries (infrastructure hosts, IPMI, etc.)
   - Or may need cleanup
3. **Validation** - Checks for duplicates in generated records
4. **Next Steps** - Instructions for updating zone file

### Example Output

```
=== DNS Smart Diff ===

Generating records from Caddy virtual hosts...
Extracting current zone file from SOPS...
Parsing zone file...

=== Records to ADD ===
metrics    IN    A    10.20.0.15
vault      IN    A    10.20.0.15

✓ 2 record(s) need to be added

=== STALE Records (in zone but not generated) ===
fw          IN    A    10.20.0.1
nas-0       IN    A    10.20.0.10
...

⚠️  22 stale record(s) found
   (These may be intentional manual entries or need cleanup)

=== Validation ===
✓ No duplicates in generated records

=== Next Steps ===
1. Copy records from the 'Records to ADD' section above
2. Edit zone file: sops hosts/luna/secrets.sops.yaml
3. Navigate to: networking.bind.zones."holthome.net"
4. Paste new records into the zone
5. Review stale records and remove if appropriate
6. Bump SOA serial (format: YYYYMMDDNN)
7. Save and exit (SOPS will re-encrypt)
8. Validate: /nix-validate host=luna
9. Deploy: /nix-deploy host=luna
```

### Prerequisites

- `nix` - For evaluating flake outputs
- `sops` - For decrypting zone file
- `named-checkzone` (optional) - For robust zone parsing (falls back to grep/awk)

### Design Decisions

**Why not fully automate?**
- Negative ROI: 8+ hours implementation for 24 min/year saved (20+ year payback)
- Architectural conflicts with K8s external-dns using rndc
- Split-brain risk between SOPS static file and BIND runtime state
- Manual step provides audit trail and prevents accidental DNS changes

**Why smart diff instead of showing all records?**
- Reduces cognitive load (most runs show 1-3 new records vs 30+ total)
- Eliminates accidental duplicates
- Saves ~2 minutes per DNS update
- 2-hour implementation with strong error-prevention benefits

**Parsing strategy:**
- Prefers `named-checkzone -D` for canonical zone file format
- Falls back to grep/awk for systems without BIND utils
- Normalizes all records to tab-separated format for comparison
- Handles YAML literal block scalars from SOPS

### Implementation Details

The script:
1. Evaluates `nix eval .#allCaddyDnsRecords --raw` to get generated records
2. Decrypts SOPS file and extracts zone content via grep pattern
3. Parses A records using `named-checkzone` or fallback regex
4. Normalizes both sets to tab-separated format
5. Uses `comm` to compute set differences (additions and removals)
6. Displays color-coded results with actionable next steps

**Code Review Validated:**
- RFC 1035 compliant for A record parsing (Perplexity validation)
- Locale-independent sorting prevents CI/local discrepancies (o3 finding)
- Proper duplicate detection for hostname conflicts (Gemini Pro + o3)
- TTY detection prevents color codes in logs (best practice)

### Maintenance

- **Add new host**: Automatically included if Caddy virtual hosts are configured
- **Change domain**: Update `DOMAIN` variable in script
- **Change SOPS location**: Update `SOPS_FILE` and `ZONE_KEY` variables
- **Support IPv6**: Extend regex patterns and awk filters for AAAA records

### Related Files

- [lib/dns-aggregate.nix](../../../lib/dns-aggregate.nix) - Flake-level DNS aggregation
- [lib/dns.nix](../../../lib/dns.nix) - Shared DNS utility functions
- [hosts/_modules/nixos/services/caddy/dns-records.nix](../../../hosts/_modules/nixos/services/caddy/dns-records.nix) - Per-host generation
- [.taskfiles/nix/Taskfile.yaml](../Taskfile.yaml) - Task runner integration
