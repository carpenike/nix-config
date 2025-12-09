# *arr Services API Key Configuration

## Overview

This document describes the declarative API key management strategy for *arr services (Sonarr, Radarr, Prowlarr) using pre-generated keys and environment variable injection.

## Architecture Decision

Based on [Servarr environment variable documentation](https://wiki.servarr.com/useful-tools#using-environment-variables-for-config), all *arr services support the pattern:

```
APPNAME__AUTH__APIKEY
```

This allows us to **pre-generate API keys** and inject them declaratively, maintaining full infrastructure-as-code principles.

## Implementation Strategy

### 1. Generate API Keys

API keys were generated using cryptographically secure random values:

```bash
# Sonarr API Key
openssl rand -hex 16  # b675b10ebfd1357e81f190d25e11dac5

# Radarr API Key
openssl rand -hex 16  # dc7a10b8a6b593df182ff360186d7aeb
```

### 2. Add Keys to SOPS Secrets

Edit the SOPS secrets file:

```bash
sops hosts/forge/secrets.sops.yaml
```

Add these entries:

```yaml
sonarr:
  api-key: b675b10ebfd1357e81f190d25e11dac5
radarr:
  api-key: dc7a10b8a6b593df182ff360186d7aeb
```

### 3. Environment Variable Injection

The module configurations need to be updated to inject these keys via environment variables:

**Sonarr Module** (`modules/nixos/services/sonarr/default.nix`):
```nix
environment = {
  TZ = cfg.timezone;
  SONARR__AUTH__APIKEY = builtins.readFile config.sops.secrets."sonarr/api-key".path;
};
```

**Radarr Module** (`modules/nixos/services/radarr/default.nix`):
```nix
environment = {
  TZ = cfg.timezone;
  RADARR__AUTH__APIKEY = builtins.readFile config.sops.secrets."radarr/api-key".path;
};
```

### 4. Bazarr Integration

Bazarr continues to use the file-based approach via its dependencies submodule:

```nix
dependencies = {
  sonarr = {
    enable = true;
    url = "http://localhost:8989";
    apiKeyFile = config.sops.secrets."sonarr/api-key".path;
  };
  radarr = {
    enable = true;
    url = "http://localhost:7878";
    apiKeyFile = config.sops.secrets."radarr/api-key".path;
  };
};
```

The Bazarr module will mount these secret files into the container and configure the service accordingly.

## Benefits of This Approach

1. **Declarative**: API keys are defined in code, not extracted post-deployment
2. **Reproducible**: Fresh deployments have known API keys from the start
3. **Idempotent**: Multiple deploys produce identical configurations
4. **Secure**: Keys are encrypted in SOPS and only decrypted at runtime
5. **Integration-Ready**: Bazarr can access keys immediately on first startup
6. **No Manual Steps**: No need to extract keys from databases after deployment

## Alternative: Auto-Generation Approach (NOT USED)

The auto-generation approach would work as follows:
1. Services start and generate random API keys
2. Keys are stored in SQLite databases
3. Admin must extract keys using: `sqlite3 /var/lib/sonarr/sonarr.db "SELECT Value FROM Config WHERE Key='apikey';"`
4. Keys must be manually added to SOPS secrets
5. Configuration must be rebuilt and redeployed

**This approach was rejected** because it breaks declarative infrastructure principles and requires manual intervention.

## Verification

After deployment, verify the API keys are working:

```bash
# Check Sonarr API
curl -H "X-Api-Key: b675b10ebfd1357e81f190d25e11dac5" http://localhost:8989/api/v3/system/status

# Check Radarr API
curl -H "X-Api-Key: dc7a10b8a6b593df182ff360186d7aeb" http://localhost:7878/api/v3/system/status

# Check Bazarr can connect to both
# (Check Bazarr logs for successful API connections)
journalctl -u podman-bazarr.service -f
```

## References

- [Servarr Environment Variables Documentation](https://wiki.servarr.com/useful-tools#using-environment-variables-for-config)
- [Sonarr Environment Variables](https://wiki.servarr.com/sonarr/environment-variables)
- [Radarr Environment Variables](https://wiki.servarr.com/radarr/environment-variables)
- Architecture discussion with Gemini 2.5 Pro (continuation_id: 32e6c99c-db5e-4c25-920e-80dcce4f5a25)

## Next Steps

1. Add API keys to `hosts/forge/secrets.sops.yaml`
2. Update Sonarr module to inject `SONARR__AUTH__APIKEY`
3. Update Radarr module to inject `RADARR__AUTH__APIKEY`
4. Build and deploy to forge
5. Verify API connectivity
6. Verify Bazarr integration
