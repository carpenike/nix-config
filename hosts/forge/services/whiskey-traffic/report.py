"""Weekly warwed.com funnel report for Operation W.W.W.

Read-only against its inputs:
  * Loki HTTP API (request log lines of whiskey-whiskey-whiskey.service), and
  * the app's SQLite DB, opened with ``mode=ro``.

For every published public event it reports, over the last N days:

  event page views -> competition page views -> registration page views
  -> registration submits (POST) -> competition entries -> Partiful RSVP snapshot

and stores the RSVP snapshot so the next run can show a week-over-week diff.

Outputs (the only writes):
  * <state-dir>/funnel-<date>.md and .json, plus latest.md / latest.json
    (0644 in a 0755 dir, so any local user can read them without sudo)
  * <state-dir>/rsvp-snapshot.json   (previous run's RSVP counts)
  * a node_exporter textfile metric (atomic tmp + rename)

Two page-view sources are reported side by side:
  * ``server`` -- regex over today's "incoming request" lines. All requests,
    bots included; Cloudflare-range, LAN and household (--exclude-regex-file)
    clients excluded. Works now.
  * ``human``  -- the structured ``msg:"public page view"`` line added by
    whiskey-whiskey-whiskey (ua_class="human", cloudflare_ip="false"). Zero
    until that change is deployed.
Delivery (email/Slack/Grafana) is intentionally not wired up yet.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sqlite3
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

UNIT_SELECTOR = '{unit="whiskey-whiskey-whiskey.service"}'
# Cloudflare edge prefixes seen as client IPs (Workers, probes, scanners).
CF_PREFIX = r'"remoteAddress":"(2a06:98c0|2400:cb00|2606:4700|2803:f800|2405:b500|2405:8100|2c0f:f248):'
STAGES = ("event", "competition", "register", "register_submit")
DEFAULT_EXCLUDE = r"^(10\..*|192\.168\..*|172\.(1[6-9]|2[0-9]|3[01])\..*|127\..*|::1|f[cd][0-9a-f]{2}:.*|fe80:.*)$"
QUERY_ERRORS = (urllib.error.URLError, OSError, RuntimeError, ValueError, KeyError)


def loki_query(base: str, query: str, at: dt.datetime, timeout: int) -> list[dict]:
    params = urllib.parse.urlencode({"query": query, "time": str(int(at.timestamp()))})
    with urllib.request.urlopen(
        f"{base}/loki/api/v1/query?{params}", timeout=timeout
    ) as resp:
        body = json.load(resp)
    if body.get("status") != "success":
        raise RuntimeError(f"loki query failed: status={body.get('status')}")
    return body["data"]["result"]


def stage_for(method: str, path: str, slug: str) -> str | None:
    base = f"/events/{slug}"
    path = path.rstrip("/") or "/"
    if method == "GET" and path == base:
        return "event"
    if method == "GET" and path == f"{base}/competition":
        return "competition"
    if method == "GET" and path == f"{base}/competition/register":
        return "register"
    if method == "POST" and path == f"{base}/competition/register":
        return "register_submit"
    return None


def server_counts(args, end: dt.datetime) -> tuple[dict, dict]:
    """(requests, unique IPs) keyed by (method, path) from raw request lines."""
    host = re.escape(args.host)
    sel = (
        f'{UNIT_SELECTOR} |= "incoming request" |~ `"host":"{host}"` '
        f'|~ `"method":"(GET|POST)","url":"/(events/[a-z0-9-]+(/competition(/register)?)?)?/?(\\?[^"]*)?"` '
        f"!~ `{CF_PREFIX}` "
        f'| regexp `"method":"(?P<method>[A-Z]+)","url":"(?P<path>[^"?]*)` '
        f'| regexp `"remoteAddress":"(?P<ip>[^"]+)"` '
        f"| ip !~ `{args.exclude_regex}`"
    )
    rng = f"[{args.days}d]"
    reqs = loki_query(
        args.loki,
        f"sum by (method, path) (count_over_time({sel} {rng}))",
        end,
        args.timeout,
    )
    uniq = loki_query(
        args.loki,
        f"count by (method, path) (sum by (method, path, ip) (count_over_time({sel} {rng})))",
        end,
        args.timeout,
    )
    to_map = lambda rows: {
        (r["metric"].get("method", ""), r["metric"].get("path", "")): int(
            float(r["value"][1])
        )
        for r in rows
    }
    return to_map(reqs), to_map(uniq)


def human_counts(args, end: dt.datetime) -> tuple[dict, dict]:
    """(page views, unique IPs) keyed by path from the structured page-view line."""
    sel = (
        f'{UNIT_SELECTOR} |= "public page view" | json '
        f'| ua_class="human" | cloudflare_ip="false" '
        f"| remoteAddress !~ `{args.exclude_regex}`"
    )
    rng = f"[{args.days}d]"
    views = loki_query(
        args.loki, f"sum by (path) (count_over_time({sel} {rng}))", end, args.timeout
    )
    uniq = loki_query(
        args.loki,
        f"count by (path) (sum by (path, remoteAddress) (count_over_time({sel} {rng})))",
        end,
        args.timeout,
    )
    to_map = lambda rows: {
        ("GET", r["metric"].get("path", "")): int(float(r["value"][1])) for r in rows
    }
    return to_map(views), to_map(uniq)


def fold(counts: dict, slug: str) -> dict:
    out = {stage: 0 for stage in STAGES}
    for (method, path), n in counts.items():
        stage = stage_for(method, path, slug)
        if stage:
            out[stage] += n
    return out


def read_db(db_path: str, start_ms: int) -> list[dict]:
    uri = f"file:{db_path}?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=10)
    try:
        con.row_factory = sqlite3.Row
        events = con.execute(
            "select op_id, slug from public_events where published = 1 order by slug"
        ).fetchall()
        result = []
        for ev in events:
            op = con.execute(
                "select title, real_date, attendees, unmatched_going_guests from operations where id = ?",
                (ev["op_id"],),
            ).fetchone()
            rsvp = {"going": 0, "maybe": 0, "declined": 0, "pending": 0, "none": 0}
            title, real_date, unmatched = "", "", 0
            if op:
                title, real_date = op["title"] or "", op["real_date"] or ""
                for a in json.loads(op["attendees"] or "[]"):
                    rsvp[a.get("rsvp") or "none"] = (
                        rsvp.get(a.get("rsvp") or "none", 0) + 1
                    )
                unmatched = len(json.loads(op["unmatched_going_guests"] or "[]"))
            entries_total = entries_window = 0
            try:
                row = con.execute(
                    "select count(*), coalesce(sum(case when created_at >= ? then 1 else 0 end), 0) "
                    "from competition_entries where op_id = ?",
                    (start_ms, ev["op_id"]),
                ).fetchone()
                entries_total, entries_window = int(row[0]), int(row[1])
            except sqlite3.OperationalError:
                pass  # no competition tables on this schema
            result.append(
                {
                    "op_id": ev["op_id"],
                    "slug": ev["slug"],
                    "title": title,
                    "date": real_date,
                    "rsvp": rsvp,
                    "rsvp_unmatched_going": unmatched,
                    "rsvp_going_total": rsvp["going"] + unmatched,
                    "entries_total": entries_total,
                    "entries_window": entries_window,
                }
            )
        return result
    finally:
        con.close()


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def metric_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--loki", default="http://127.0.0.1:3100")
    p.add_argument("--db", required=True)
    p.add_argument("--state-dir", required=True)
    p.add_argument("--metrics-file", required=True)
    p.add_argument("--host", default="warwed.com")
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--timeout", type=int, default=300)
    p.add_argument(
        "--exclude-regex-file",
        help="file holding a full-match regex of client IPs to drop (household); LAN-only default if missing",
    )
    args = p.parse_args()
    args.exclude_regex = DEFAULT_EXCLUDE
    if args.exclude_regex_file and Path(args.exclude_regex_file).exists():
        candidate = Path(args.exclude_regex_file).read_text().strip()
        if candidate and "`" not in candidate:
            args.exclude_regex = candidate

    end = dt.datetime.now(dt.timezone.utc)
    start = end - dt.timedelta(days=args.days)
    local = lambda t: t.astimezone().strftime("%Y-%m-%d %H:%M %Z")
    state = Path(args.state_dir)
    state.mkdir(parents=True, exist_ok=True)

    events = read_db(args.db, int(start.timestamp() * 1000))
    errors: list[str] = []
    try:
        srv_req, srv_uniq = server_counts(args, end)
    except QUERY_ERRORS as exc:  # report what we can
        srv_req, srv_uniq = {}, {}
        errors.append(f"server counts: {exc}")
    try:
        hum_views, hum_uniq = human_counts(args, end)
    except QUERY_ERRORS as exc:
        hum_views, hum_uniq = {}, {}
        errors.append(f"human counts: {exc}")

    snap_path = state / "rsvp-snapshot.json"
    previous = json.loads(snap_path.read_text()) if snap_path.exists() else {}

    for ev in events:
        ev["server_requests"] = fold(srv_req, ev["slug"])
        ev["server_unique_ips"] = fold(srv_uniq, ev["slug"])
        ev["human_views"] = fold(hum_views, ev["slug"])
        ev["human_unique_ips"] = fold(hum_uniq, ev["slug"])
        prev = previous.get(ev["op_id"])
        ev["rsvp_previous"] = prev
        ev["rsvp_going_delta"] = (
            None
            if prev is None
            else ev["rsvp_going_total"] - prev.get("going_total", 0)
        )

    home = {
        "server_requests": srv_req.get(("GET", "/"), 0),
        "server_unique_ips": srv_uniq.get(("GET", "/"), 0),
        "human_views": hum_views.get(("GET", "/"), 0),
        "human_unique_ips": hum_uniq.get(("GET", "/"), 0),
    }

    report = {
        "generated_at": end.isoformat(),
        "window": {
            "start": start.isoformat(),
            "end": end.isoformat(),
            "days": args.days,
        },
        "host": args.host,
        "homepage": home,
        "events": events,
        "errors": errors,
    }

    lines = [
        f"# {args.host} weekly funnel",
        "",
        f"Window: {local(start)} → {local(end)} ({args.days} days)",
        "",
        (
            "`server` = GET/POST request lines (bots included; Cloudflare-range, LAN and household IPs excluded); "
            "`human` = structured `public page view` lines with ua_class=human (0 until the Whiskey change ships). "
            "Format: requests / unique IPs."
        ),
        "",
        (
            f"Homepage `/`: server {home['server_requests']} / {home['server_unique_ips']}, "
            f"human {home['human_views']} / {home['human_unique_ips']}"
        ),
        "",
    ]
    for ev in events:
        s, su, h, hu = (
            ev["server_requests"],
            ev["server_unique_ips"],
            ev["human_views"],
            ev["human_unique_ips"],
        )
        delta = ev["rsvp_going_delta"]
        lines += [
            f"## {ev['title'] or ev['slug']} (`/events/{ev['slug']}`, {ev['date']})",
            "",
            "| Stage | server | human |",
            "|---|---|---|",
            f"| Event page | {s['event']} / {su['event']} | {h['event']} / {hu['event']} |",
            f"| Competition page | {s['competition']} / {su['competition']} | {h['competition']} / {hu['competition']} |",
            f"| Register page | {s['register']} / {su['register']} | {h['register']} / {hu['register']} |",
            f"| Register submits (POST) | {s['register_submit']} / {su['register_submit']} | n/a |",
            f"| Competition entries | {ev['entries_window']} new, {ev['entries_total']} total | |",
            (
                f"| Partiful RSVP going | {ev['rsvp_going_total']} "
                f"({'first snapshot' if delta is None else f'{delta:+d} vs last run'}) | |"
            ),
            "",
            (
                f"RSVP snapshot: going {ev['rsvp']['going']}, maybe {ev['rsvp']['maybe']}, "
                f"declined {ev['rsvp']['declined']}, pending {ev['rsvp']['pending']}, "
                f"unset {ev['rsvp']['none']}, unmatched Partiful going {ev['rsvp_unmatched_going']}."
            ),
            "",
        ]
    if errors:
        lines += ["## Errors", ""] + [f"- {e}" for e in errors] + [""]
    markdown = "\n".join(lines)

    stamp = end.astimezone().strftime("%Y-%m-%d")
    atomic_write(state / f"funnel-{stamp}.md", markdown)
    atomic_write(state / f"funnel-{stamp}.json", json.dumps(report, indent=2))
    atomic_write(state / "latest.md", markdown)
    atomic_write(state / "latest.json", json.dumps(report, indent=2))
    atomic_write(
        snap_path,
        json.dumps(
            {
                ev["op_id"]: {
                    "at": end.isoformat(),
                    "going_total": ev["rsvp_going_total"],
                    "rsvp": ev["rsvp"],
                }
                for ev in events
            },
            indent=2,
        ),
    )

    m = [
        "# HELP whiskey_funnel_stage Requests/views per funnel stage over the report window.",
        "# TYPE whiskey_funnel_stage gauge",
    ]
    for ev in events:
        slug = metric_label(ev["slug"])
        for source, key in (
            ("server", "server_requests"),
            ("server_unique", "server_unique_ips"),
            ("human", "human_views"),
            ("human_unique", "human_unique_ips"),
        ):
            for stage in STAGES:
                m.append(
                    f'whiskey_funnel_stage{{slug="{slug}",stage="{stage}",source="{source}"}} {ev[key][stage]}'
                )
    m += [
        "# HELP whiskey_funnel_entries Competition entries.",
        "# TYPE whiskey_funnel_entries gauge",
    ]
    for ev in events:
        slug = metric_label(ev["slug"])
        m.append(
            f'whiskey_funnel_entries{{slug="{slug}",scope="window"}} {ev["entries_window"]}'
        )
        m.append(
            f'whiskey_funnel_entries{{slug="{slug}",scope="total"}} {ev["entries_total"]}'
        )
    m += [
        "# HELP whiskey_funnel_rsvp Partiful RSVP snapshot by state.",
        "# TYPE whiskey_funnel_rsvp gauge",
    ]
    for ev in events:
        slug = metric_label(ev["slug"])
        for state_name, n in ev["rsvp"].items():
            m.append(f'whiskey_funnel_rsvp{{slug="{slug}",state="{state_name}"}} {n}')
        m.append(
            f'whiskey_funnel_rsvp{{slug="{slug}",state="unmatched_going"}} {ev["rsvp_unmatched_going"]}'
        )
    m += [
        "# HELP whiskey_funnel_homepage_views Homepage requests/views over the report window.",
        "# TYPE whiskey_funnel_homepage_views gauge",
    ]
    for source, key in (
        ("server", "server_requests"),
        ("server_unique", "server_unique_ips"),
        ("human", "human_views"),
        ("human_unique", "human_unique_ips"),
    ):
        m.append(f'whiskey_funnel_homepage_views{{source="{source}"}} {home[key]}')
    m += [
        "# HELP whiskey_funnel_report_errors Number of Loki query failures in the last run.",
        "# TYPE whiskey_funnel_report_errors gauge",
        f"whiskey_funnel_report_errors {len(errors)}",
        "# HELP whiskey_funnel_report_last_run_timestamp_seconds Unix time of the last report.",
        "# TYPE whiskey_funnel_report_last_run_timestamp_seconds gauge",
        f"whiskey_funnel_report_last_run_timestamp_seconds {int(end.timestamp())}",
        "",
    ]
    atomic_write(Path(args.metrics_file), "\n".join(m))
    print(markdown)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
