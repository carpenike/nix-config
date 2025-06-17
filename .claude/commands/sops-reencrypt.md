# /sops-reencrypt

Re-encrypt all SOPS secrets in the repository.

## Usage

```
/sops-reencrypt
```

## Implementation

```bash
task sops:re-encrypt
```

## What This Does

The task automatically:
1. Finds all `*.sops.yaml` files in the repository
2. Decrypts each file in-place
3. Re-encrypts each file with current keys from `.sops.yaml`

## When to Use

### Required Scenarios
- **New team member**: After adding someone's GPG/age key to `.sops.yaml`
- **Key rotation**: After updating or replacing encryption keys
- **Key removal**: After removing someone's access from `.sops.yaml`
- **Migration**: When moving between GPG and age keys

### Optional Scenarios
- **Regular maintenance**: Periodic re-encryption as security practice
- **Before major deployments**: Ensure all secrets use latest key configuration

## Process Flow

```bash
# For each *.sops.yaml file found:
sops --decrypt --in-place <file>  # Decrypt to plaintext
sops --encrypt --in-place <file>  # Re-encrypt with current keys
```

## Key Configuration

Encryption keys are managed in `.sops.yaml`:
- **GPG keys**: For user-specific access
- **Age keys**: For automated/host-specific access
- **Creation rules**: Define which keys encrypt which files

## Safety Considerations

### Before Re-encryption
- **Backup**: Ensure all secrets are safely backed up
- **Key verification**: Verify all required keys are available
- **Access validation**: Confirm team members can decrypt with their keys

### After Re-encryption
- **Test decryption**: Verify you can still decrypt secrets
- **Validate deployments**: Run `/nix-validate` to ensure configs work
- **Team verification**: Have team members test their access

## Troubleshooting

### Common Issues
- **Missing keys**: Error if `.sops.yaml` references unavailable keys
- **Permission errors**: Ensure proper GPG/age key permissions
- **Network access**: GPG may need keyserver access for public keys

### Recovery
If re-encryption fails:
```bash
# Restore from git if files are corrupted
git checkout HEAD -- hosts/*/secrets.sops.yaml

# Or restore from backup
```

## Notes

- This affects ALL secret files in the repository
- Requires access to decryption keys for existing secrets
- Changes file modification times but not content
- Essential for maintaining proper access control
