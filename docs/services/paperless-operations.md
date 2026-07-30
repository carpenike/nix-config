# Paperless Operations

This guide documents the Paperless-ngx deployment on `forge`, the temporary
Paperless-AI integration, document review workflows, storage, monitoring,
backups, and the planned migration to native Paperless AI.

## Current Architecture

| Component | Deployment | Endpoint |
| --- | --- | --- |
| Paperless-ngx | Native NixOS service | `https://paperless.holthome.net` |
| Paperless-AI | Pinned Podman container | `https://paperless-ai.holthome.net` |
| Database | Local PostgreSQL with pgBackRest | Internal |
| LLM | Direct Anthropic API via the OpenAI-compatible endpoint | External |
| Authentication | Native PocketID OIDC for Paperless; PocketID/Caddy for Paperless-AI | Internal and external |

Paperless-AI is a temporary compatibility layer. Do not add new architectural
dependencies to it unless required for security or data integrity. See
[Native AI Migration](#native-ai-migration).

## Storage Layout

| Path | Storage | Purpose |
| --- | --- | --- |
| `/var/lib/paperless` | Local ZFS dataset | Search index, classifier, thumbnails, configuration state, and portable exports |
| `/var/lib/paperless/export` | Local ZFS dataset | Weekly portable `document_exporter` output |
| `/mnt/data/paperless/media` | NAS NFS share | Original and archived documents |
| `/mnt/data/paperless/consume` | NAS NFS share | Scanner and manual intake directory |
| `/var/lib/paperless-ai` | Local ZFS dataset | Paperless-AI SQLite history, RAG index, and cached models |

Paperless web, consumer, scheduler, exporter, and document backup jobs require
`mnt-data.mount`. They fail closed rather than running against an empty mount.

The consume directory is recursive and polled every 10 seconds because NFS does
not reliably propagate inotify events. Subdirectory-derived tags are disabled;
Paperless-AI and the managed taxonomy own tag assignment.

## Document Intake and Review

New documents receive `workflow:needs-review` through a native Paperless
workflow. Paperless-AI processes unprocessed documents every 30 minutes and:

- assigns an existing accepted tag when confident;
- adds `workflow:ai-processed` after processing;
- writes proposed namespaced tags and reasons to the
  `workflow:suggested-tags` custom field when no accepted tag fits;
- retains `workflow:needs-review` until a substantive accepted tag is present.

The **Workflow / Needs Review** saved view appears in Ryan's sidebar and dashboard.
Its table includes the suggested-tags custom field.

### Accept a Suggested Tag

1. Open **Workflow / Needs Review**.
2. Review `workflow:suggested-tags` on the document.
3. Create the accepted namespaced tag in Paperless, for example
   `procurement:rfi`.
4. Add `workflow:reprocess` to the document. This can be done in bulk.
5. The five-minute `paperless-ai-reprocess.timer` resets only those document IDs
   in Paperless-AI, clears stale workflow markers and suggestions, and starts an
   immediate scan.
6. The bridge preserves accepted tags across Paperless-AI's metadata update. A
   successful classification removes `workflow:needs-review` and
   `workflow:reprocess`, leaving the accepted tag and `workflow:ai-processed`.

Accepted tags persist because taxonomy reconciliation seeds required tags but
does not prune user-created tags.

## Managed Taxonomy

Baseline tags:

- `finance:statement`
- `finance:tax`
- `finance:paystub`
- `finance:insurance`
- `finance:invoice`
- `finance:receipt`
- `finance:loan`
- `finance:investment`
- `workflow:needs-review`
- `workflow:ai-processed`
- `workflow:reprocess`

Unknown model-generated tags are not created automatically. Accepted tags are
created by a reviewer and then become eligible for future AI classification.

Finance custom fields:

- `finance:tax-year`
- `finance:account-last4`
- `finance:statement-period`
- `finance:amount-due`
- `workflow:suggested-tags`

Ten Ryan-owned saved views cover each finance category, Needs Review, and the
reprocessing queue. `paperless-finance-bootstrap.service` creates or reconciles
the fields, views, and new-document workflow idempotently.

## Power-User Settings

Paperless stores future archive files using:

```text
{{ created_year }}/{{ correspondent }}/{{ document_type }}/{{ title }}
```

Empty path components are removed. ASN barcode recognition is enabled with the
`ASN` prefix for physical originals. Generic barcode page splitting remains
disabled to avoid unintended document splits.

## Schedules

| Job | Schedule |
| --- | --- |
| Paperless deep health | Every minute |
| Paperless-AI app/provider health | Hourly |
| Paperless-AI scan | Every 30 minutes |
| Reprocessing queue | Every 5 minutes |
| Managed taxonomy reconciliation | Daily with randomized delay |
| Portable Paperless export | Sunday at 00:30 |
| Local and R2 document backups | Daily with randomized delay |
| Paperless/Paperless-AI state backup | Daily |
| ZFS replication | Approximately every 15 minutes |

The native exporter stops Paperless components while generating a consistent
portable export, then restarts them. Its output contains documents, thumbnails,
and metadata. API tokens are not included and must be regenerated after import.

## Backup and Recovery

Paperless recovery spans three data boundaries:

1. PostgreSQL metadata uses pgBackRest with local/NFS and Cloudflare R2
   repositories plus WAL archiving.
2. Original documents in `/mnt/data/paperless/media` are backed up independently
   to `nas-primary` and `r2-offsite` with Restic.
3. Local Paperless and Paperless-AI state use ZFS snapshots, Syncoid replication,
   and snapshot-based Restic backups.

The portable export is protected through the Paperless state dataset. The
non-privileged raw-document backup account intentionally cannot traverse the
private export directory.

## Monitoring

Paperless monitoring includes:

- public Gatus endpoint checks;
- authenticated `/api/status/` checks for PostgreSQL, Redis, Celery, index,
  classifier, sanity checks, migration state, and storage capacity;
- unacknowledged failed-task metrics;
- systemd alerts for web, consumer, scheduler, task queue, Tika, Gotenberg, and
  exporter units;
- stale-healthcheck and component-health alerts.

Paperless-AI monitoring includes:

- container and `/health` checks;
- hourly end-to-end Anthropic model checks through `/api/rag/status`;
- provider, application, staleness, service, and reprocessing alerts.

Useful commands:

```bash
systemctl status paperless-web paperless-consumer paperless-task-queue
systemctl status podman-paperless-ai paperless-ai-reprocess.timer
systemctl start paperless-healthcheck.service paperless-ai-healthcheck.service
systemctl start paperless-exporter.service
journalctl -u paperless-ai-reprocess.service -n 100
```

## Native AI Migration

Paperless-ngx 3.0.x includes native advisory AI for suggestions, similar-document
retrieval, and document chat. Stable 3.0 uses a `sqlite-vec` vector store under
`/var/lib/paperless/llm_index`; it does not use FAISS in the final release.

The current production migration is intentionally deferred because:

- `forge` currently runs Paperless 2.19.6;
- nixpkgs unstable still packages Paperless 2.20.x;
- no active nixpkgs Paperless 3.0 update PR exists;
- Paperless 3.0.1 had a broken database migration and 3.0.4 was released only on
  2026-07-28;
- 3.0 adds a substantial LlamaIndex, OpenAI, HuggingFace, Torch, and sqlite-vec
  dependency stack;
- native AI is advisory and does not replace the finance custom-field extraction
  and automatic reprocessing bridge by itself.

Migration trigger:

1. nixpkgs ships a stable Paperless 3.0.x package and corresponding NixOS module
   support;
2. the package builds on `x86_64-linux` in this repository;
3. a canary database migration, OIDC login, exporter/import, consumer, and native
   AI test pass;
4. backups and rollback are verified immediately before production activation.

Planned native configuration:

- enable `PAPERLESS_AI_ENABLED`;
- use an OpenAI-compatible LLM endpoint or a deliberately deployed Ollama
  service;
- use `huggingface` embeddings for local vector generation;
- keep AI configuration declarative and ensure database Application
  Configuration values do not override environment settings;
- retain finance custom fields, saved views, workflows, taxonomy, and backups;
- replace or explicitly preserve custom-field extraction before removing
  Paperless-AI.

After a successful canary, remove the Paperless-AI container, API-token bridge,
state dataset, reprocessing service, dedicated monitoring, secrets, and backups.
