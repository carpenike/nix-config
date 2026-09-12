# Atrium owner identity bootstrap

The owner mapping comes from the live Pocket ID management API using the
documented tooling in `~/src/network-config`, not a synthetic fixture or an
email match. Read-only discovery on 2026-09-12 resolved exactly one active
`ryan` account, verified the issuer/JWKS endpoints and confirmed the current
RS256 signing metadata. The privileged API key was never exported.

The two reviewed non-secret values are:

- `hosts/forge/atrium/identity-bootstrap.json`: the canonical `ryan` human
  principal, explicitly selected `admin`/`adult` roles and native subject.
- `hosts/forge/atrium/pocketid-authority.json`: the independently configured
  Pocket ID issuer, resolver audience, JWKS URI and algorithm/lifetime bound.

`identity.nix` derives the registry authority/principal fragment and the
bootstrap settings from those same values. It deliberately does not seed
runtime group observations, instance access or policy grants. Pocket ID
administrator status is corroborating account metadata, not the source of
Atrium role authority.

## Refreshing the source values

Run `network-config/scripts/pocketid-audit.sh` first, retaining its output
privately. Its `pocketid-atrium-bootstrap.sh` exporter follows all user pages,
requires an exact active username and rechecks the selected ID. Supply explicit
principal/authority/role values and a new private output directory. Review the
two exported JSON documents before changing the files here; never overwrite an
existing runtime identity binding merely because a later API lookup differs.

The exporter is GET-only. No Pocket ID users, groups, client registrations,
API resources, secrets, access tokens or refresh grants are mutated by this
mapping preparation.

## Installed operator inputs

Forge's package module installs:

```text
/etc/atrium/bootstrap/identity.json
/etc/atrium/bootstrap/resolver.json
```

The original settings use `/var/lib/atrium-resolver`, verified HTTPS authority
trust, and `isolated_harness = false`. They contain no signing configuration or
permission policy: this remains the identity-only input.
The [Forge runtime foundation](atrium-forge-runtime.md) now installs explicit
identity/signing/TLS initializer units, protected listener units and private
custody. Its complete registry and native/model adoption remain blocked on the
reviewed inputs documented there; missing policy fails listener startup.

For the foundation's new first-use installation, use the explicit
`atrium-initialize.service` operator unit documented in the runtime guide.
The original identity-only CLI, run as the state owner, remains:

```sh
atrium-resolver --config /etc/atrium/bootstrap/resolver.json \
  bootstrap --enrollment /etc/atrium/bootstrap/identity.json
```

Do not run both initialization paths or a second bootstrap to update an existing installation. The actual
resolver rejects a populated store and unknown authorities. Deployment tests
execute the real packaged command against temporary private state, prove the
valid first initialization, and require repeated/foreign-authority refusals.
No running resolver has been initialized by the package build.

## Authentication boundary

The desired resolver audience is `https://atrium.holthome.net/resolver`.
The read-only API discovery found no Atrium OIDC client or resource registration.
Identity export and local bootstrap do not manufacture a matching upstream
access token; the dedicated client/resource setup and actual user authorization
remain separate from the mapping itself. Existing Home MCP and Whiskey
clients are not repurposed or widened.
