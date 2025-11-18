# Cooklang Federation Feed Sync

> **Purpose:** Keep our `feeds.xml` (actually the Cooklang federation `feeds.yaml` registry) in lockstep with the upstream [cooklang/federation](https://github.com/cooklang/federation) project so that new publishers show up in search without manual DB surgery.


## Source of Truth

| Artifact | Location |
| --- | --- |
| Upstream registry | `https://raw.githubusercontent.com/cooklang/federation/main/config/feeds.yaml` |
| Local checked-in copy | `hosts/files/cooklang-federation/feeds.yaml` |
| Runtime path on forge | `${dataDir}/config/feeds.yaml` (copied during service start) |
| Environment variable | `FEED_CONFIG_PATH` (exported by the NixOS module) |

By default the module will fall back to the config bundled inside the packaged binary, but on Forge we explicitly point `modules.services.cooklangFederation.feedConfigFile` at the tracked file above. This lets us refresh feeds without touching the upstream pin.

## Refresh Workflow


1. **Fetch latest upstream registry**

   ```bash
   task cooklang:update-feeds
   # or run the script directly if task isn't installed
   ./scripts/update-cooklang-feeds.sh
   ```

   Both commands download the canonical `feeds.yaml` and overwrite `hosts/files/cooklang-federation/feeds.yaml` if anything changed (then print `git status`).

2. **Review & commit**

   ```bash
   git add hosts/files/cooklang-federation/feeds.yaml
   git diff --stat
   git commit -m "cooklang: refresh feeds registry"
   ```

3. **Deploy to Forge**

   ```bash
   task nix:apply-nixos host=forge
   ```

   The module copies the refreshed file into `/data/cooklang-federation/config/feeds.yaml`, sets `FEED_CONFIG_PATH`, and the service replays the sync at boot. (A restart is part of every switch.)

4. **Verify**

   ```bash
   curl -s https://fedcook.holthome.net/api/feeds | jq '.[0] | {title,url}'
   ```

   or visit `/feeds` in the UI to confirm the counts.

## Publishing Checklist (for new community feeds)

Borrowed from the `/about` page so the process lives in git:

1. **Write recipes in Cooklang** – keep `.cook` files in version control.
2. **Expose a feed** – either an Atom/RSS feed with Cooklang content (`feed_type: web`) or a GitHub repo containing `.cook` files (`feed_type: github`).
3. **Host it** – Netlify/Vercel, GitHub Pages, Render, or any HTTPS static host. Make sure `feed.xml` is public, sets `Content-Type: application/atom+xml`, and serves `.cook` files as UTF-8 text.
4. **Register with the federation** – fork `cooklang/federation`, edit `config/feeds.yaml`, and open a PR. CI validates URL reachability, duplicates, and deny patterns.
5. **Keep it updated** – bump `<updated>` timestamps when recipes change; the crawler relies on conditional GET (ETag/Last-Modified) to stay efficient.

Once the upstream PR merges, re-run the refresh workflow above to ingest the new feed locally.

## Operational Notes

- `scripts/update-cooklang-feeds.sh` is idempotent and fish-friendly; it just needs network access.
- Because the service only syncs feeds on startup, any manual refresh should be followed by `systemctl restart cooklang-federation` (handled automatically during a NixOS switch).
- If we ever need to test a local-only feed before upstream merge, drop it into `hosts/files/cooklang-federation/feeds.yaml`, annotate with a comment, and open a PR upstream afterwards.
- For historical auditing, rely on git history of the tracked file; it mirrors the GitOps story the upstream project follows.
