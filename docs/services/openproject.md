# OpenProject (bot task queue)

OpenProject Community Edition on forge is the shared task queue for the five
Grok bots (Executive Assistant, Social Planner, Finances, Homelab Manager,
Grok Bot) and for Ryan. A custom MCP server around API v3 is planned on top of it.

| | |
|---|---|
| Host config | `hosts/forge/services/openproject.nix` |
| Module | `modules/nixos/services/openproject/default.nix` |
| Bootstrap scripts | `hosts/forge/services/openproject/` |
| URL | `https://tasks.holthome.net` (Cloudflare tunnel `forge` → Caddy) |
| Loopback | `http://127.0.0.1:8072` (web container port 8080) |
| Reserved | `tasks-mcp.holthome.net`, `127.0.0.1:8073` (MCP), `10.88.0.1:8074` (webhook receiver). These are disabled stubs. |
| Image | `openproject/openproject:17.9.2-slim@sha256:7b50be7f…` (pinned by digest, Renovate-tracked) |

## Layout and sizing

```
Cloudflare tunnel "forge" ──► Caddy (PocketID gate, bypass /api/ /oauth/ /health_checks/default)
                                 │
                                 ▼ 127.0.0.1:8072
   podman-openproject-seeder (oneshot: schema load / db:migrate + db:seed)
        │ Requires/After
        ├─► podman-openproject-web     puma, 2 workers × 2–5 threads
        └─► podman-openproject-worker  GoodJob, 5 threads (+ cron-style scheduled jobs)
                 │                          │
                 ▼                          ▼
   PostgreSQL 17 (shared, db `openproject`)   Redis (shared, DB index 2, Rails cache)
                 │
   /var/lib/openproject  =  tank/services/openproject  (attachments under files/)
```

Notes:

- **Containers, not native.** nixpkgs (25.11 and unstable) has no OpenProject
  package or NixOS module. A native build would mean packaging a Rails 8 /
  Ruby 4 app with its Angular frontend and keeping its Gemfile.lock and npm
  lockfile in step every two weeks. The official image is upstream's
  supported path, and Renovate updates the digest. The cost is a 2 GB image
  and running as a non-default UID (see below).
- **No cron container.** Upstream's `cron` container only runs an IMAP
  mail-receive loop. Scheduled jobs run inside the GoodJob worker
  (`good_job_enable_cron`, on by default). Add the container back if
  incoming email is ever wanted.
- **No memcached and no hocuspocus.** The Rails cache uses forge's shared
  Redis (`OPENPROJECT_RAILS__CACHE__STORE=redis`, DB 2, namespace
  `openproject`). Redis runs `allkeys-lru` with 256 MB shared across
  services. Cache keys are safe to evict, but a busy cache competes with
  Tracearr and Dispatcharr for that 256 MB. If that ever matters, add a
  dedicated memcached on a private podman network (upstream's layout). The
  collaborative-editing server (hocuspocus) is not deployed, so real-time
  co-editing of documents is off.
- **Runs as UID 1069.** The image's `app` user is UID 1000, which is `ryan`
  on forge. The containers run as `openproject` (1069, from
  `lib/service-uids.nix`) with a tmpfs on `/app/tmp`. This has not been
  tested on forge yet. If something under `/app` turns out to need writes,
  the symptom is a permission error in `journalctl -u podman-openproject-seeder`.
- **Memory.** Upstream's minimum is 4 cores, 4 GB RAM and 20 GB disk. The
  caps are web 2.5 GiB (1 GiB reserved), worker 1.5 GiB (512 MiB reserved)
  and seeder 1.5 GiB (oneshot). Steady state is about 1.5–2.5 GiB, with a
  ceiling of about 4 GiB. Forge has 31 GiB total and only about 8 GiB free
  today, so **this adds real memory pressure**. Watch
  `container_memory_usage_bytes` for a week and trim the caps to roughly
  2.5 × the 7-day peak, as other forge services do. To reclaim about
  600 MB, set `web.workers = 1`.
- **DB connections.** `DATABASE_URL` uses `pool=10`. The worst case is about
  16 connections (2 web workers × 5, plus 5 worker threads, plus the
  seeder), out of PostgreSQL's 100.

## Secrets to add before deploy

Add these with `sops hosts/forge/secrets.sops.yaml`. They are declared in
`hosts/forge/secrets.nix` and rendered into
`sops.templates."openproject-env"`:

```yaml
openproject:
  secret_key_base: <openssl rand -hex 64>
  database_password: <openssl rand -hex 32>     # hex only: embedded verbatim in DATABASE_URL
  admin_password: <printf '%s!' "$(openssl rand -base64 24)">  # seeded `admin` login, change at first login
```

> **Forge auto-upgrades nightly at 04:00 from `main`.** If this merges before
> the three keys exist, sops-nix cannot render the secrets. `validateSopsFiles`
> fails the build, so that night's upgrade, and every one after it, fails
> until the keys are added. Add the secrets first (or in the same push),
> then merge.

## First deploy

1. Add the secrets (above) and merge.
2. Deploy forge. The first start provisions role and database `openproject`
   (with the `btree_gist`, `pg_trgm` and `unaccent` extensions), then the
   seeder loads the schema and seeds. This takes a few minutes.
   `journalctl -fu podman-openproject-seeder`.
3. Log in at `https://tasks.holthome.net`. PocketID comes first (admin
   group), then OpenProject's own login: `admin` / the sops `admin_password`.
   Set a new password and enable 2FA (Administration → Authentication → Two-factor).
4. Administration → System settings: confirm the host name is
   `tasks.holthome.net` and the protocol is `https`. Both are locked by env.
5. Administration → Authentication → OAuth applications: **enable the
   built-in OAuth applications** (needed by the mobile app).
6. Create Ryan's own (non-admin, or admin) user if `admin` should stay break-glass only.
7. After the first nightly backups exist, set
   `protection.allowEmptyBootstrap = false` in `openproject.nix`. Then move
   `openproject` into `standardServicePaths` and `failClosedUnits`
   (`podman-openproject-seeder`) in `flake.nix`.

## Access model

PocketID (caddy-security) is a browser-session gate. OpenProject's own
authentication covers API tokens, OAuth bearer tokens and sessions. The two
interact like this:

| Client | Path(s) | Can it pass a forward-auth/Access browser login? | Handling |
|---|---|---|---|
| Ryan in a browser | everything | yes | PocketID, then OpenProject login |
| Bots / MCP server | `/api/v3/*` with `Authorization: Basic apikey:<token>` or Bearer | no | **bypassed**; OpenProject token auth |
| Mobile app (iOS/Android) | `/oauth/authorize` (in a browser sheet), `/oauth/token`, `/api/v3/*` | only the browser-sheet step | `/oauth/` and `/api/` **bypassed**. The browser sheet still hits `/login`, which is gated, so you do PocketID once in the sheet and then the OpenProject login. Token exchange and API calls carry a bearer token. |
| Future frontend (OAuth client) | same as the mobile app | same | same |
| Outgoing webhooks | OpenProject → receiver | n/a (egress) | no ingress needed. Private targets need the SSRF allow-list (see Webhooks). |
| Gatus | `/health_checks/default` | no | bypassed. It only returns `default: PASSED`. `/health_checks/all` stays gated. |

Why not Cloudflare Access? It behaves the same way as the PocketID gate:
browser flows work, but bearer-token API clients and the native app's
token calls cannot present an Access cookie. Service tokens would have to
be issued to every client, and the app has no way to send them. The repo
already standardizes on PocketID, so this keeps one gate.

Why not OIDC login with PocketID? In OpenProject, OpenID Connect (and SAML)
login is an **Enterprise add-on**. Community Edition offers internal accounts,
LDAP and header-based SSO (`auth_source_sso`). PocketID has no LDAP, and
header SSO would mean trusting a header injected by caddy-security. That is
possible, but it hands identity to the proxy and needs matching logins.
Ryan should decide on it separately (see open questions). The recommendation is
**the gate as defence in depth on the UI, with OpenProject auth on
`/api/` and `/oauth/`.**

Hardening on top:

- `OPENPROJECT_SELF__REGISTRATION=0`: no sign-ups, and the bots are created by admin.
- 2FA for human accounts. Bots never log in interactively (random password, tokens only).
- Basic auth on API v3 is on by default (`apikey:<token>`). Bearer tokens
  from OAuth also work.
- A narrower option is to keep the API LAN-only. Drop `/api/` from
  `bypassPaths`, and the MCP server, being on forge, uses the loopback URL.
  That breaks the mobile app, which needs `/api/v3` publicly.

Proxy settings set by the module: `OPENPROJECT_HOST__NAME=tasks.holthome.net`,
`OPENPROJECT_HTTPS=true` (https links, secure cookies) and
`OPENPROJECT_HSTS=false`. Caddy already sends HSTS and handles http→https,
and with Rails HSTS off, loopback `http://127.0.0.1:8072` calls are not
redirected. `OPENPROJECT_ADDITIONAL__HOST__NAMES="127.0.0.1 localhost"` lets
loopback clients pass Rails host authorization.

## Bot users and roles

Plan: each bot is its own user. Each bot gets its own private project and is
a member of `bots-shared`. Ryan (admin) sees everything.

| Login | Own project |
|---|---|
| `bot-executive-assistant` | `bot-executive-assistant` |
| `bot-social-planner` | `bot-social-planner` |
| `bot-finances` | `bot-finances` |
| `bot-homelab-manager` | `bot-homelab-manager` |
| `bot-grok` | `bot-grok` |
| all five | `bots-shared` |

Role: the seeded **Member** role by default (`--role` to change). A
dedicated "Bot" role is better: work packages can be viewed, added, edited
and commented on, with no project admin and no member management. Roles
cannot be created through API v3, so create it in the UI (Administration →
Users and permissions → Roles) and pass `--role Bot`.

```bash
# On forge, after first deploy. Create an admin API token in the UI first
# (My account → Access tokens → + API token) and keep it out of shell history:
install -m 600 /dev/stdin /run/user/$UID/op-admin-token   # paste, Ctrl-D
OP_ADMIN_TOKEN_FILE=/run/user/$UID/op-admin-token \
  python3 hosts/forge/services/openproject/bootstrap.py --dry-run
OP_ADMIN_TOKEN_FILE=/run/user/$UID/op-admin-token \
  python3 hosts/forge/services/openproject/bootstrap.py
# API v3 cannot mint tokens; this uses rails runner inside the web container:
sudo bash hosts/forge/services/openproject/mint-api-tokens.sh   # -> /root/openproject-bot-tokens.tsv (0600)
```

The bootstrap is idempotent: it only creates missing projects, users and
memberships. Bot e-mail addresses use a placeholder domain
(`bots.holthome.net`). No SMTP is configured, so nothing is sent. Put the
minted tokens in sops for the MCP server (for example
`openproject-mcp/token_<bot>`), then `shred -u` the file.

OAuth alternative for bots: an OAuth application with a *Client Credentials
User* lets a confidential client act as one bot without a long-lived personal
token. That is one application per bot. API tokens are simpler for a
server-side MCP and are what the bootstrap assumes.

## Webhooks

Webhooks can only be set up in the UI (Administration → API and webhooks →
Webhooks → + Webhook):

- Payload URL: `http://host.containers.internal:8074/webhooks/openproject`
  is a placeholder for the MCP server's or bot-routines' receiver. Inside the
  containers, `host.containers.internal` is the podman0 gateway `10.88.0.1`.
- Events: `work_package:created`, `work_package:updated`,
  `work_package_comment:comment` (plus `project:*` if useful).
- Projects: all, or `bots-shared` plus the bot projects.
- Secret: set one. Each request then carries `X-OP-Signature: sha1=<HMAC-SHA1(secret, body)>`,
  which the receiver must verify.
- **SSRF protection:** OpenProject refuses webhook targets in private ranges
  unless they are allow-listed. `openproject.nix` adds `10.88.0.1/32` to
  `ssrfAllowlist` only when `mcpEnabled = true`. A public receiver URL needs
  no allow-list.
- Delivery runs as a background job in the worker. Each webhook keeps a
  delivery log in the UI. Do not treat webhooks as the only trigger: receivers
  should also reconcile by polling (`updatedAt` filter).

## MCP wrapper

`openproject.nix` contains a disabled stub (`mcpEnabled = false`). Enabling
it adds a placeholder `openproject-mcp.service` that exits with an error,
the vhost `tasks-mcp.holthome.net` on the `forge` tunnel (no caddySecurity,
since the MCP server does its own OAuth as `homelab-mcp` does), podman0
port 8074 for the webhook receiver, and the SSRF allow-list entry.

Design notes for the server:

- Talk to `http://127.0.0.1:8072/api/v3` with the calling bot's API token
  (`Authorization: Basic base64("apikey:" + token)`), so OpenProject's
  permissions and audit trail apply per bot.
- **Slim the HAL+JSON.** Map `_links.*.href` IDs and `title`s to flat fields
  (`id, subject, status, assignee, project, priority, dueDate, lockVersion,
  description.raw`), drop `_links` actions and `description.html`, and page
  with `pageSize` and `offset`. Filters go in the `filters` JSON query param,
  for example `[{"status":{"operator":"o","values":[]}},{"assignee":{"operator":"!*","values":[]}}]`.
- **Atomic claim:** read the work package, then
  `PATCH /api/v3/work_packages/{id}` with
  `{"lockVersion": <n>, "_links": {"assignee": {"href": "/api/v3/users/<bot>"}, "status": {"href": "/api/v3/statuses/<in-progress>"}}}`.
  A stale `lockVersion` returns **409** (`urn:openproject-org:api:v3:errors:UpdateConflict`).
  Treat that as "someone else got it", re-read, and skip it if the
  assignee is now someone else. Send `notify=false` to suppress mail.
- Comments: `POST /api/v3/work_packages/{id}/activities` with `{"comment":{"raw":"…"}}`.
- Webhook-driven wake-ups, with polling as the fallback.
- OpenProject's built-in `/mcp` endpoint is an Enterprise add-on and is not
  available in Community Edition, which is why this wrapper exists.

## Backups, restore and upgrades

- **Database:** pgBackRest covers it automatically, as part of the shared
  cluster (repo1 NFS plus repo2 R2, WAL archiving every 5 minutes, PITR).
- **Attachments** (`tank/services/openproject`): sanoid snapshots, syncoid to
  nas-1, Restic to the NAS (`service-openproject`) and to R2
  (`openproject-offsite`), and preseed restore (syncoid, then local). The
  protection class is `standard` and every tier is satisfied (see the
  `protection-manifest` check).
- Work packages reference attachments by DB row. To restore, take the
  attachments snapshot closest to, but not older than, the DB recovery point.
  A few orphaned files are harmless. Missing files just show as broken
  downloads.
- OpenProject's built-in UI backup (`backup_enabled`) remains available for ad-hoc exports.
- **Upgrades:** Renovate bumps the tag and digest. On switch, the seeder
  re-runs (`restartTriggers = [ image ]`) and migrates before web and worker
  start. Upgrade major versions (17 → 18) one at a time, reading the release
  notes. Take a manual `pgbackrest backup --type=incr` first, because
  migrations are not reversible and a DB rollback means PITR.

## Monitoring

- Container alerts: `OpenProjectWebServiceDown`, `OpenProjectWorkerServiceDown`
  (plus the generated RestartChurn companions).
- `OpenProjectSeederServiceDown`: migrate/seed failed, so web and worker are
  being held back.
- Gatus: `http://127.0.0.1:8072/health_checks/default` (app) and
  `https://tasks.holthome.net/health_checks/default` (through Caddy and the tunnel).
- The homepage tile is in the Productivity group.
