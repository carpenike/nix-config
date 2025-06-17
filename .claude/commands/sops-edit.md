# /sops-edit

Edit encrypted secrets with automatic path resolution and safety reminders.

## Usage

```
/sops-edit host=<hostname> [file=<filename>]
```

## Parameters

- `host` (required): The host whose secrets to edit
- `file` (optional): Specific secrets file (default: `secrets.sops.yaml`)

## Examples

```bash
# Edit default secrets for luna
/sops-edit host=luna

# Edit specific secrets file
/sops-edit host=luna file=wireguard.sops.yaml

# Edit common secrets
/sops-edit host=common file=users.sops.yaml
```

## Implementation

### Host-specific secrets
```bash
# Default secrets file
sops hosts/{hostname}/secrets.sops.yaml

# Specific secrets file
sops hosts/{hostname}/{filename}
```

### Common/shared secrets
```bash
# For host=common
sops hosts/_modules/common/secrets/{filename}
```

## File Locations

Based on repository structure:

### Host-specific
- `hosts/luna/secrets.sops.yaml`
- `hosts/rydev/secrets.sops.yaml`
- `hosts/rymac/secrets.sops.yaml`
- `hosts/nixos-bootstrap/secrets.sops.yaml`

### Common/shared
- `hosts/_modules/common/secrets/`
- Custom locations as needed

## Safety Reminders

After editing secrets, always:

1. **Validate configuration**: Run `/nix-validate host=<hostname>`
2. **Test deployment**: Consider using `/nix-deploy host=<hostname> --build-only` first
3. **Verify decryption**: Ensure target host has proper age/GPG keys

## Notes

- SOPS will decrypt, open your editor, then re-encrypt on save
- Requires proper GPG or age key configuration
- Never commit plaintext secrets to repository
- Use separate test keys for development/testing
- Secrets are decrypted on target systems during deployment
