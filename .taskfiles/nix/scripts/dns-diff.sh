#!/usr/bin/env bash
# DNS Smart Diff - Shows only DNS records that need to be added/removed
# Compares generated Caddy records against current BIND zone file

set -euo pipefail

# Configuration
DOMAIN="holthome.net"
SOPS_FILE="hosts/luna/secrets.sops.yaml"
ZONE_KEY="networking.bind.zones.\"${DOMAIN}\""

# Colors for output (only if TTY)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Create temp directory
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"; exit' EXIT INT TERM

echo -e "${BLUE}=== DNS Smart Diff ===${NC}"
echo ""

# Step 1: Get generated records from Nix (normalize to tabs with locale-independent sort)
echo "Generating records from Caddy virtual hosts..."
LC_ALL=C nix eval .#allCaddyDnsRecords --raw | LC_ALL=C awk '{print $1 "\t" $2 "\t" $3 "\t" $4}' | LC_ALL=C sort | uniq > "${TMPDIR}/generated.txt"

# Check if we got any records
if [ ! -s "${TMPDIR}/generated.txt" ]; then
    echo -e "${YELLOW}⚠️  No records generated. Check that Caddy virtual hosts are configured.${NC}"
    exit 1
fi

# Step 2: Extract and canonicalize current zone file
echo "Extracting current zone file from SOPS..."
if ! sops -d "${SOPS_FILE}" | grep -A 10000 "holthome.net: |" | tail -n +2 > "${TMPDIR}/zone-raw.txt" 2>/dev/null; then
    echo -e "${RED}❌ Failed to decrypt zone file from SOPS${NC}"
    echo "   Make sure you have the decryption key configured"
    exit 1
fi

# Check if we got any zone content
if [ ! -s "${TMPDIR}/zone-raw.txt" ]; then
    echo -e "${RED}❌ No zone content found in SOPS file${NC}"
    exit 1
fi

# Step 3: Canonicalize zone file with named-checkzone
echo "Parsing zone file..."
if command -v named-checkzone >/dev/null 2>&1; then
    # Use named-checkzone to canonicalize and extract A records
    if ! LC_ALL=C named-checkzone "${DOMAIN}" "${TMPDIR}/zone-raw.txt" 2>/dev/null \
        | LC_ALL=C awk '$4 == "A" {print $1 "\tIN\tA\t" $5}' \
        | LC_ALL=C sort | uniq > "${TMPDIR}/current.txt"; then
        echo -e "${YELLOW}⚠️  Warning: named-checkzone failed, falling back to simple parsing${NC}"
        # Fallback: simple grep for A records
        LC_ALL=C grep -E '^\s*\S+\s+(IN\s+)?A\s+[0-9.]+' "${TMPDIR}/zone-raw.txt" \
            | LC_ALL=C awk '{print $1 "\tIN\tA\t" $(NF)}' \
            | LC_ALL=C sort | uniq > "${TMPDIR}/current.txt" || true
    fi
else
    echo -e "${YELLOW}⚠️  named-checkzone not found, using simple parsing${NC}"
    # Fallback: simple grep for A records
    LC_ALL=C grep -E '^\s*\S+\s+(IN\s+)?A\s+[0-9.]+' "${TMPDIR}/zone-raw.txt" \
        | LC_ALL=C awk '{print $1 "\tIN\tA\t" $(NF)}' \
        | LC_ALL=C sort | uniq > "${TMPDIR}/current.txt" || true
fi

# Step 4: Compute differences (with locale-independent comm)
LC_ALL=C comm -13 "${TMPDIR}/current.txt" "${TMPDIR}/generated.txt" > "${TMPDIR}/to-add.txt"

# Step 5: Display results
echo ""
echo -e "${GREEN}=== Records to ADD ===${NC}"
if [ -s "${TMPDIR}/to-add.txt" ]; then
    cat "${TMPDIR}/to-add.txt"
    echo ""
    echo -e "${GREEN}✓ ${NC}$(wc -l < "${TMPDIR}/to-add.txt") record(s) need to be added"
else
    echo -e "${GREEN}✓ No new records to add${NC}"
fi

# Step 6: Check for duplicates in generated records (same hostname with different IPs)
echo ""
echo -e "${BLUE}=== Validation ===${NC}"
DUPLICATES=$(cut -f1 "${TMPDIR}/generated.txt" | sort | uniq -d)
if [ -n "$DUPLICATES" ]; then
    echo -e "${RED}❌ Duplicate hostnames detected in generated records:${NC}"
    echo "$DUPLICATES"
    echo -e "${RED}   This indicates the same hostname has multiple IP addresses${NC}"
else
    echo -e "${GREEN}✓ No duplicates in generated records${NC}"
fi

# Step 7: Generate SOA serial
SUGGESTED_SERIAL=$(date +%Y%m%d00)
echo ""
echo -e "${BLUE}=== SOA Serial ===${NC}"
echo -e "Suggested serial: ${GREEN}${SUGGESTED_SERIAL}${NC}"
echo "   (Format: YYYYMMDDNN - increment NN if multiple updates today)"

# Step 8: Instructions
if [ -s "${TMPDIR}/to-add.txt" ]; then
    echo ""
    echo -e "${BLUE}=== Next Steps ===${NC}"
    echo "1. Copy records from the 'Records to ADD' section above"
    echo "2. Edit zone file: sops ${SOPS_FILE}"
    echo "3. Navigate to: ${ZONE_KEY}"
    echo "4. Paste new records into the zone"
    echo "5. Update SOA serial to: ${SUGGESTED_SERIAL} (or higher)"
    echo "6. Save and exit (SOPS will re-encrypt)"
    echo "7. Validate: /nix-validate host=luna"
    echo "8. Deploy: /nix-deploy host=luna"
else
    echo ""
    echo -e "${GREEN}✓ Zone file is in sync with generated records!${NC}"
fi
