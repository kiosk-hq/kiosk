# Kiosk hosted live demos — deploy runbook

Runbook for hosting all 7 Kiosk demo Rails apps on **one small VPS**, one
**Postgres** cluster (DB-per-app), fronted by **Caddy** (auto-TLS), each app a
loopback **Puma** under **systemd** — sized to survive an HN stampede.

This directory is the *app-side* handoff; DNS + VPS provisioning is the operator's.

## Files in this directory

| File | What it is |
|------|-----------|
| `Caddyfile` | One vhost per demo subdomain → loopback Puma; automatic TLS. |
| `postgres-init.sql` | 7 databases + 7 least-privilege login roles (DB-per-app). |
| `kiosk-demo@.service` | Parameterised systemd unit: one Puma per app (`%i`). |
| `env/<app>.env.example` | Per-app env template (×7). Copy to `/etc/kiosk-demo/<app>.env`. |
| `prune.sh` | Daily cron: prune old anonymous accounts, re-seed shared catalog. |
| `README.md` | This runbook. |

## Per-demo map

| Demo | Subdomain | Port | PoW difficulty | Stripe (test) |
|------|-----------|------|----------------|---------------|
| getgrocery | `getgrocery.demo.kiosk.tech` | 3001 | **low** (~1 s, poke-friendly) | yes |
| atablefor  | `atablefor.demo.kiosk.tech` (or apex `atablefor.us`) | 3002 | **HIGH** (~30 s, "beware: intensive PoW") | yes |
| hoteling   | `hoteling.demo.kiosk.tech` | 3003 | **low** | — |
| skooti     | `skooti.demo.kiosk.tech` | 3004 | **HIGH** (~30 s, "beware: intensive PoW") | — |
| stylish    | `stylish.demo.kiosk.tech` | 3005 | **low** | — |
| philslist  | `philslist.demo.kiosk.tech` | 3006 | **low** | — |
| tudu       | `tudu.demo.kiosk.tech` | 3007 | **low** | — |

**PoW difficulty is a feature** (design §8.4): most demos run a low/fast toll so
a poker can register in ~1 s and still SEE the toll; **skooti** and **atablefor**
run a high memory+CPU-hard toll behind a "beware: intensive PoW" banner so the
DoS shield is tangible first-hand. `KIOSK_POW_DIFFICULTY` in each env file drives
this per demo.

> **How it wires (WIRED).** Each demo's initializer reads
> `ENV["KIOSK_POW_DIFFICULTY"]` (`low` default, `high` opt-in) via
> `lib/pow_difficulty.rb` and sets its Equihash params accordingly:
> - **low** → `{n:96,k:5}` — sub-second reference solve, poke-friendly.
> - **high** → `{n:168,k:7}` — the shipped Equihash default: ~10 s and ~1.3 GiB
>   per proof on the reference (numpy) solver — a real memory+CPU toll. Verified
>   to clear (measured 8.9–9.5 s) end-to-end.
>
> **Unset ⇒ low**, so local `demo:setup`/CI never pay the heavy toll and never
> hang — the high params are the hosted-deploy setting only. When `high`, the
> initializer also adds a `pow_difficulty` + `pow_notice` ("beware: memory- and
> CPU-intensive proof-of-work…") to the `owner` block of
> `/.well-known/kiosk.json`, and the 402 challenge already carries the heavy
> `{n,k}` — so an agent/reader sees the toll up front. Env files ship
> skooti/atablefor = `high`, the rest = `low`.

## What the operator does vs. what's automated

**Operator (manual):**
1. **DNS.** Either a wildcard `*.demo.kiosk.tech → VPS_IP` (one A record, add
   apps later with no DNS change) or one A record per subdomain above. If you
   want the flagship domain, point `atablefor.us` (+`www`) at the VPS too.
2. **Provision the VPS** (2–4 GB; design §2 sizes all 7 ≈ 2 GB Puma → 4 GB
   comfortable). Install Postgres 16, Caddy, Ruby (`.mise.toml` pins the
   version), and a non-login `kiosk` service user.
3. **Set real secrets.** Replace every `REPLACE_*` value in each
   `env/<app>.env.example` (secret key base, DB passwords, signing key, PoW
   secret, Stripe **test** keys for getgrocery + atablefor). Copy to
   `/etc/kiosk-demo/<app>.env`, mode `0600`, owner `kiosk`. The templates are
   shell-source-safe as written, so `set -a; . file` works.
4. **Run the steps below**, or hand over shell access.

**Automated (this runbook provides):** the Caddy vhosts, the SQL to create all
DBs + roles, the systemd unit template, the env templates, and the daily prune
cron. No app code changes are required to run multi-app/one-Postgres — each
demo already ships a production `database.yml` pointing at its own DB + role.

### Steps

```sh
# 0. Put the monorepo checkout under /srv/kiosk (owned by the kiosk user).
#    Each app lives at /srv/kiosk/kiosk-demo-<name>.

# 1. Postgres: create the 7 DBs + least-privilege roles.
#    Pass each password as a *quoted* psql variable (inner single quotes).
sudo -u postgres psql -v ON_ERROR_STOP=1 \
  -v gg_pw="'…'" -v af_pw="'…'" -v ho_pw="'…'" -v sk_pw="'…'" \
  -v st_pw="'…'" -v pl_pw="'…'" -v td_pw="'…'" \
  -f /srv/kiosk/reference/deploy/postgres-init.sql
#    Then set max_connections=100 in postgresql.conf (design §2) and reload.

# 2. Per app: install gems, precompile assets, prepare the DB (schema + seed).
for app in getgrocery atablefor hoteling skooti stylish philslist tudu; do
  cd /srv/kiosk/kiosk-demo-$app
  bundle install
  set -a; . /etc/kiosk-demo/$app.env; set +a
  RAILS_ENV=production bin/rails assets:precompile db:prepare
done
#    db:prepare creates the schema, runs migrations (incl. the kiosk schema +
#    opt-in RLS), and seeds the shared catalog on first run.

# 3. systemd: install the template unit and enable one instance per app.
sudo cp /srv/kiosk/reference/deploy/kiosk-demo@.service /etc/systemd/system/
sudo mkdir -p /etc/kiosk-demo   # env files live here (Operator step #3)
sudo systemctl daemon-reload
for app in getgrocery atablefor hoteling skooti stylish philslist tudu; do
  sudo systemctl enable --now kiosk-demo@$app
done
#    Check: systemctl status kiosk-demo@getgrocery ; journalctl -u kiosk-demo@skooti -f

# 4. Caddy: point it at this Caddyfile and reload.
sudo cp /srv/kiosk/reference/deploy/Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
#    Caddy fetches a cert per subdomain on first request (HTTP-01). For a single
#    wildcard cert instead, see the DNS-01 note in the Caddyfile header.

# 5. Cron: daily housekeeping.
#    0 4 * * *  /srv/kiosk/reference/deploy/prune.sh >> /var/log/kiosk-prune.log 2>&1
```

## Payments — Stripe TEST mode

getgrocery (SetupIntent card-on-file) and atablefor (booking deposit) run
Stripe in **test mode**. A poker completes a real `off_session` PaymentIntent
end-to-end with **no real charge** and **no live key on the box**. Publish the
test card on each demo's landing:

> **Test card:** `4242 4242 4242 4242` — any future expiry, any CVC, any ZIP.
> More cards: <https://docs.stripe.com/testing>

## Poke it — the "curl one-liner" (design §3)

The register gate is a memory-hard PoW by design, so the "true" one-liner ships
a copy-paste **solver** (`kiosk-pow-equihash/solve.py`). Hosted difficulty is
low (~1 s) on most demos; skooti/atablefor are intentionally ~30 s (you'll feel
it — that's the point). Flow: **discover → register (solve PoW) → query**.

```sh
# 0. Discover: who/where/which verbs (no auth).
curl -s https://getgrocery.demo.kiosk.tech/.well-known/kiosk.json | jq .

# 1. Instant look at the wire, no register (design §3c): read the schema.
curl -s https://getgrocery.demo.kiosk.tech/kiosk/schema | jq .

# 2. Full flow — register with the bundled solver, then query.
BASE=https://getgrocery.demo.kiosk.tech

#    a) get a register challenge (returns the Equihash params to solve)
CH=$(curl -s "$BASE/kiosk/auth/challenge")

#    b) solve it with the bundled solver (from kiosk-pow-equihash/):
#       python3 solve.py  reads the challenge on stdin, prints the proof.
PROOF=$(echo "$CH" | python3 kiosk-pow-equihash/solve.py)   # ~1 s low / ~30 s high

#    c) register (agent key + solved proof) → returns a token
TOKEN=$(curl -s -X POST "$BASE/kiosk/auth/register" \
  -H 'content-type: application/json' \
  -d "$PROOF" | jq -r .token)

#    d) call a query as the registered assistant
curl -s -X POST "$BASE/kiosk/query" \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"name":"catalog","params":{}}' | jq .
```

> The exact challenge/proof JSON shape is what the demo's `/kiosk/auth/challenge`
> returns and `solve.py` consumes — publish the copy-paste-exact snippet on each
> demo landing once the hosted challenge format is pinned. skooti/atablefor show
> the "beware: memory- and CPU-intensive PoW" banner so pokers expect the ~30 s.

## Live-activity telemetry — WIRED (opt-in)

Aggregate, privacy-safe **live-activity counters** are now wired into all seven
demos (app-layer, NOT kiosk-core — satellite neutrality). Off by default; a demo
that never sets `KIOSK_TELEMETRY=1` behaves exactly as before.

**Shared store.** Provision the one shared DB once:

    psql -v ON_ERROR_STOP=1 -v tm_pw="'<telemetry-pw>'" -f telemetry-init.sql

This creates the `kiosk_demo_telemetry` DB + `kiosk_telemetry` LOGIN role + the
append-only `demo_telemetry_events(app, action_kind, agent_hash, at)` table.
(The apps also create this table idempotently at runtime, so a fresh boot
against an empty shared DB self-heals — but run the SQL for least-privilege
grants.)

**Per-app env** (add to each `env/<app>.env`):

    KIOSK_TELEMETRY=1
    KIOSK_TELEMETRY_DB_URL=postgres://kiosk_telemetry:<pw>@127.0.0.1/kiosk_demo_telemetry
    KIOSK_TELEMETRY_SALT=<a DISTINCT random salt PER APP>   # keeps agent hashes non-joinable

`KIOSK_TELEMETRY_DB_URL` unset ⇒ the app writes to its OWN DB (local/CI
testable). Set it on every hosted app to the shared DB so the landing aggregate
spans all demos.

**Endpoint.** Each app serves `GET /demo/activity.json` (only when
`KIOSK_TELEMETRY=1`), cached `max-age=10`, `Access-Control-Allow-Origin: *`:

    { assistants_active_10m, registered_total,
      actions_last_hour: { browsed, ordered, booked, paid, … },
      generated_at, scope }

`?scope=app` = this demo's own page counts; default `scope=all` = the ALL-apps
aggregate the **kiosk.tech landing tile** fetches (point the tile at any hosted
app's `/demo/activity.json`, or a dedicated one, all reading the shared DB).

**Privacy guard.** Counts only. `agent_hash` is a per-app *salted* hash used
solely for distinct-counts — never surfaced, **never joined across apps**
(joining an agent across demos would be the cross-provider tracking Kiosk
forbids; the per-app salt makes it impossible by construction). No IPs, no UAs,
no raw agent id, no per-assistant detail.

**Demonstrate before real traffic.** `rake demo:telemetry` (in getgrocery)
seeds simulated events and prints both aggregates — the exact JSON the endpoint
and landing tile return.

Still open (not this change): a per-app `demo:prune` (+ idempotent `demo:seed`)
rake task so `prune.sh` reclaims disk from throwaway registrations (§6) —
`prune.sh` already calls these if present and no-ops safely if not.
