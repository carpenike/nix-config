# Runbook: registering the Household Advisor Signal bot

One-time manual procedure, performed by a human, to give the `signal-api`
service a working Signal account. Everything else about the service is
declarative; this is the part that cannot be.

Expect **30–45 minutes**, most of it waiting on SMS and on Signal's rate
limiter. Do it in one sitting — a half-registered account is awkward to
resume.

- **Service module:** [`default.nix`](./default.nix)
- **Host config:** [`hosts/forge/services/signal-api.nix`](../../../../hosts/forge/services/signal-api.nix)
- **Runs on:** forge, container `signal-api`, loopback `http://127.0.0.1:8484`

---

## 0. Before you start

**The API has no authentication.** Anything that can reach it can send
messages as the bot. On forge it is bound to `127.0.0.1` and an iptables guard
limits it to the `root`, `homelab-mcp` and `gatus` accounts, so:

> Every `curl` in this runbook must run **on forge, as root** (`sudo curl …`).
> The same command as your normal user gets a TCP reset — that is the guard
> working, not a bug.

Never expose this service through Caddy or the Cloudflare Tunnel.

### Prerequisites

1. The module is deployed and the container is healthy:

   ```bash
   task nix:apply-nixos host=forge
   ```

   ```bash
   ssh forge 'systemctl is-active podman-signal-api && sudo curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8484/v1/health'
   ```

   Expect `active` and `204`.

2. Confirm the mode is `json-rpc` and note the build:

   ```bash
   ssh forge 'sudo curl -sS http://127.0.0.1:8484/v1/about | jq'
   ```

3. A phone that can receive the verification SMS at the number below.

> **Expect one red check and possibly a Pushover alert while you work.** Gatus
> monitors *Signal Account* (`/v1/accounts`) as well as *Signal API*
> (`/v1/health`). On a fresh deployment there is no account, so the account
> check is red and pages after ~25 minutes. That is correct — it goes green on
> its own once you finish step 4.

---

## 1. Acquire a dedicated VoIP number

The bot needs its **own** number. Do not use a personal number: registering it
with Signal here would move that person's Signal account onto this container.

Requirements:

- Can receive SMS (voice fallback works too, but SMS is simpler).
- Not currently registered with Signal under any other account.
- **Long-lived.** If the number is reclaimed by the provider and re-issued to
  someone else, that person can take over the bot's Signal identity. This is
  the single biggest long-term risk in this setup.

Two reasonable options:

| Option | Cost | Notes |
| --- | --- | --- |
| **Twilio** | ~$1.15/mo + per-SMS | Recommended. Numbers stay yours while billing is current; SMS shows up in the Twilio console, no phone needed. |
| **Google Voice** | Free | Works, but Google reclaims numbers after ~9 months of inactivity, and Voice numbers are sometimes rejected by Signal. If you use one, send a text from it occasionally. |

The number is used **once**, at registration. After that the account lives in
the container's dataset and the number only matters if you ever have to
re-register.

Write the number down in E.164 form (`+15551234567`) — you will paste it into
every command below. It also gets recorded in SOPS in step 8.

---

## 2. Register the number

Try without a captcha first:

```bash
ssh forge 'sudo curl -sS -X POST -H "Content-Type: application/json" -d "{}" http://127.0.0.1:8484/v1/register/+15551234567'
```

- Empty response / HTTP 201 → registration accepted, **go to step 4**.
- `{"error":"Captcha required for verification (null)\n"}` → step 3.
- `{"error":"...RateLimit..."}` or HTTP 429 → Signal is throttling. Wait an
  hour and retry; do not hammer it. If it persists, see Troubleshooting.

## 3. Solve the captcha (only if demanded)

1. Open <https://signalcaptchas.org/registration/generate.html> in a desktop
   browser and open the developer console **before** solving.
2. Solve the captcha.
3. The console logs a line like:
   `Prevented navigation to "signalcaptcha://signal-hcaptcha-short.5fad97ac-….registration.…" due to an unknown protocol.`
4. Copy the value **without** the `signalcaptcha://` prefix.
5. Register with it (the token is single-use and expires within minutes — have
   the command ready to paste):

   ```bash
   ssh forge 'sudo curl -sS -X POST -H "Content-Type: application/json" -d "{\"captcha\":\"signal-hcaptcha-short.PASTE_HERE\"}" http://127.0.0.1:8484/v1/register/+15551234567'
   ```

If it still reports a captcha requirement, the token expired — generate a
fresh one and retry immediately.

## 4. Verify with the SMS code

The SMS arrives within a minute or two (check the Twilio console for a Twilio
number). The code looks like `123-456`; send it either with or without the
hyphen:

```bash
ssh forge 'sudo curl -sS -X POST -H "Content-Type: application/json" http://127.0.0.1:8484/v1/register/+15551234567/verify/123456'
```

Confirm the account now exists:

```bash
ssh forge 'sudo curl -sS http://127.0.0.1:8484/v1/accounts | jq'
```

The response should list `+15551234567`.

> **json-rpc note:** the resident signal-cli daemon picks up the new account
> automatically. If subsequent calls insist the number is not registered,
> restart the container once (`sudo systemctl restart podman-signal-api`) —
> that re-runs the helper that wires the daemon up to registered accounts.

---

## 5. Set the profile name

Signal refuses group sends from an account with no profile name ("Cannot send
message to group - please first update your profile"), so this is required,
not cosmetic:

```bash
ssh forge 'sudo curl -sS -X PUT -H "Content-Type: application/json" -d "{\"name\":\"Household Advisor\"}" http://127.0.0.1:8484/v1/profiles/+15551234567'
```

Expect HTTP 204.

## 6. Set a username

A username means group members see `householdadvisor.42` instead of the bot's
phone number — worth doing before anyone is invited.

```bash
ssh forge 'sudo curl -sS -X POST -H "Content-Type: application/json" -d "{\"username\":\"householdadvisor\"}" http://127.0.0.1:8484/v1/accounts/+15551234567/username | jq'
```

The response returns the full username with its discriminator plus a
`username_link`:

```json
{ "username": "householdadvisor.42", "username_link": "https://signal.me/#eu/…" }
```

Record the full username (with discriminator) in the family group description
or wherever the household keeps that sort of thing.

Optionally hide the phone number from other Signal users — do this from the
Signal app on a linked device, or leave it: the number is a throwaway VoIP
number that nobody outside the household knows.

---

## 7. Get the group ID

**Preferred:** have a human create the family group in the normal Signal app
and invite the bot (search by the username from step 6). This keeps group
ownership with a person, not with the container.

Then list the groups the bot is in:

```bash
ssh forge 'sudo curl -sS http://127.0.0.1:8484/v1/groups/+15551234567 | jq ".[] | {name, id, member}"'
```

Copy the `id` of the family group — it looks like
`group.Y2tSemFFZDRWbVJ6TmpKYVFTQUVzYXNh…`. Make sure `member` is `true` (if the
bot was invited but has not accepted, it will show as pending; accept from a
linked device or use the join endpoint).

<details>
<summary>Alternative: create the group from the bot side</summary>

```bash
ssh forge 'sudo curl -sS -X POST -H "Content-Type: application/json" -d "{\"name\":\"Household\",\"members\":[\"+15559990000\",\"+15559990001\"]}" http://127.0.0.1:8484/v1/groups/+15551234567 | jq'
```

Returns the new group's id. Members get an invite they must accept.
</details>

## 8. Record the number and group ID

Both values belong in configuration, not in code. The group ID is not a secret
but it lives next to the number so there is one place to look.

They go into the existing `homelab-mcp` env secret, which is the file the
future `signal_send` tool reads:

```bash
task sops:edit host=forge
```

Under `homelab-mcp: env:`, add these lines to the dotenv blob:

```dotenv
HOMELAB_MCP_SIGNAL_BASE_URL=http://127.0.0.1:8484
HOMELAB_MCP_SIGNAL_NUMBER=+15551234567
HOMELAB_MCP_SIGNAL_GROUP_ID=group.Y2tSemFFZDRWbVJ6TmpKYVFTQUVzYXNh
```

Then apply so sops-nix re-renders the secret and restarts the consumer:

```bash
task nix:apply-nixos host=forge
```

> These keys are consumed by the `signal_send` tool in `~/src/mcp`, which is a
> separate piece of work. Adding them now is harmless — homelab-mcp ignores
> env vars it does not know about — and it means registration is fully
> finished in one sitting.

---

## 9. Smoke test

### 9a. Send a message

```bash
ssh forge 'sudo curl -sS -X POST -H "Content-Type: application/json" -d "{\"message\":\"Household Advisor: transport test, please ignore.\",\"number\":\"+15551234567\",\"recipients\":[\"group.Y2tSemFFZDRWbVJ6TmpKYVFTQUVzYXNh\"]}" http://127.0.0.1:8484/v2/send'
```

Expect a `{"timestamp":"…"}` response and the message visible in the family
group, attributed to **Household Advisor**. If the sender shows as a phone
number, step 5 or 6 did not take.

### 9b. Registration survives a restart

This is the whole point of the persistent dataset — verify it, do not assume
it:

```bash
ssh forge 'sudo systemctl restart podman-signal-api'
```

```bash
ssh forge 'sleep 60; sudo curl -sS -o /dev/null -w "health=%{http_code}\n" http://127.0.0.1:8484/v1/health; sudo curl -sS http://127.0.0.1:8484/v1/accounts'
```

Expect `health=204` and the number still listed. Then re-send 9a and confirm a
second message arrives.

### 9c. The API is not reachable by anything else

```bash
# As a normal (non-approved) user on forge: expect "Connection reset by peer"
ssh forge 'curl -sS --max-time 5 http://127.0.0.1:8484/v1/health; echo "exit=$?"'
```

That reset is the intentional host UID guard, not evidence that Podman's
published port is broken. Test the Homelab MCP consumer path as its service
user instead:

```bash
ssh forge 'sudo -u homelab-mcp curl -fsS http://127.0.0.1:8484/v1/about | jq "{mode, version}"'
```

Expect `mode` to be `json-rpc`. This follows the same
`HOMELAB_MCP_SIGNAL_BASE_URL` path as `signal_send`; testing as your login user
will always get an immediate TCP reset unless that user was deliberately added
to `localAccess.allowedUsers`.

```bash
# From your workstation: expect a timeout / refusal, never a 204
curl -sS --max-time 5 http://forge.holthome.net:8484/v1/health; echo "exit=$?"
```

### 9d. Monitoring is green

Check <https://status.holthome.net> under *Infrastructure*. All three endpoints
should now be green:

| Endpoint | Polls | Proves |
| --- | --- | --- |
| **Signal API** | `/v1/health`, 60s | the HTTP server is serving (a bare 204 — nothing more) |
| **Signal API Consumer Path** | `/v1/about`, 60s | the exact loopback URL used by Homelab MCP traverses published-port DNAT and returns the expected `json-rpc` API |
| **Signal Account** | `/v1/accounts`, 300s | the signal-cli daemon answers *and* the bot account exists |

The account check may take up to 5 minutes to flip green after step 4.

### 9e. The crown jewels are being protected

```bash
ssh forge 'zfs list -t snapshot tank/services/signal-api | tail -3'
```

After the next nightly cycle, both Restic jobs should have run:

```bash
ssh forge 'systemctl list-units "restic-backup-*signal*" --all'
```

`restic-backup-service-signal-api` (NAS) and
`restic-backup-signal-api-offsite` (R2) are both expected.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Captcha required for verification` even with a token | Token expired (they last minutes) or was pasted with the `signalcaptcha://` prefix. Generate a fresh one. |
| HTTP 429 / rate limit on register | Signal throttles registration attempts per number and per IP. Wait an hour. Repeated failures can require a rate-limit challenge: `POST /v1/accounts/<number>/rate-limit-challenge`. |
| No SMS arrives | Number cannot receive SMS from short codes (common with some VoIP providers). Retry with `{"use_voice": true}` for a voice call, or use a different provider. |
| `Cannot send message to group - please first update your profile` | Step 5 was skipped or failed. |
| `User <number> is not registered` right after verifying | The signal-cli daemon has not picked up the account. Restart the container once. If it recurs, the container is resource-starved — check the memory limit in the module. |
| Sends stopped working after months of silence | Almost always image age: signal-cli's protocol support goes stale and Signal rejects old clients. Bump the pinned image (see below) before debugging anything else. |
| `curl: (56) Connection reset by peer` from a script | The caller's UID is not in `localAccess.allowedUsers`. Add it in `hosts/forge/services/signal-api.nix` — deliberately, and only for a service that should be able to speak as the bot. |
| Container healthy, both Gatus checks red | Gatus checks from the `gatus` user; confirm it is still in `localAccess.allowedUsers`. |
| *Signal API* green, *Signal Account* red | The container is serving but has no account — either registration was never completed, or a restore brought back an empty dataset. See "If the dataset is lost". |

### Bumping the image

The pin lives in [`default.nix`](./default.nix). Get the digest for a new tag:

```bash
TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:bbernhard/signal-cli-rest-api:pull" | jq -r .token); curl -sI -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.oci.image.index.v1+json" https://registry-1.docker.io/v2/bbernhard/signal-cli-rest-api/manifests/0.101 | grep -i docker-content-digest
```

Update tag and digest together, deploy, then re-run smoke test 9a. The account
dataset is untouched by an image bump.

### If the dataset is lost

There is no way to recover the account from Signal's side. Recovery order:

1. Restore from ZFS snapshot / syncoid replica / Restic. `preseed-signal-api`
   attempts syncoid then a local snapshot automatically whenever it finds a
   dataset without the `holthome:preseed_complete` marker; the offsite Restic
   copy is a deliberate manual decision:

   ```bash
   ssh forge 'sudo restic -r /mnt/nas-backup --password-file /run/secrets/restic/password snapshots --tag signal-api'
   ```

2. **Always confirm the account came back**, whichever way it was restored:

   ```bash
   ssh forge 'sudo curl -sS http://127.0.0.1:8484/v1/accounts | jq'
   ```

   > A container that started on an empty dataset is *indistinguishable from a
   > healthy one* at `/v1/health` — it answers 204 with or without an account,
   > which is exactly why the *Signal Account* check exists. `[]` here means
   > the identity is gone.

3. Only if all copies are gone: re-run this entire runbook. Re-registering the
   same number produces new identity keys, so every group member sees a safety
   number change, and the bot must be re-invited to the group.

### Retiring the bot

```bash
ssh forge 'sudo curl -sS -X POST http://127.0.0.1:8484/v1/unregister/+15551234567'
```

Then remove the service from `hosts/forge/default.nix`, delete the SOPS keys,
and release the VoIP number.
