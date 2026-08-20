# Kiosk hosted live demos — deploy runbook

Runbook for hosting the 7 Kiosk demo Rails apps **plus the KYC broker**
— 8 apps — on **one small VPS**, one **Postgres** cluster (DB-per-app), fronted
by **Caddy** (auto-TLS), each app a loopback **Puma** under **systemd** — sized
to survive an HN stampede.

This directory is the *app-side* handoff; DNS + VPS provisioning is the operator's.

## Files in this directory

| File | What it is |
|------|-----------|
| `Caddyfile` | One vhost per app subdomain (8) → loopback Puma; automatic TLS. Carries the **required** per-IP edge rate-limit, shipped commented (needs the `caddy-ratelimit` module — see below). |
| `postgres-init.sql` | 8 databases + 8 least-privilege login roles (DB-per-app; 7 demos + the KYC broker). Names default to the shipped ones and are overridable — see [Database names](#database-names). |
| `kiosk-demo@.service` | Parameterised systemd unit: one Puma per app (`%i`). |
| `env/<app>.env.example` | Per-app env template (7 demos + `kyc-demo.env.example` for the broker). Copy to `/etc/kiosk-demo/<app>.env`. |
| `telemetry-init.sql` | The ONE shared live-activity store: `kiosk_demo_telemetry` DB + `kiosk_telemetry` login role + the append-only events table. Only needed if you turn telemetry on — see [Live-activity telemetry](#live-activity-telemetry--wired-opt-in). |
| `demo-reset.sh` | Run ON THE BOX to put demo data back to a clean, freshly-seeded state: drops + reseeds the six non-getgrocery demos, additively reseeds getgrocery (keeps the order the landing cites); `--all` wipes getgrocery too. This is the disk-reclaim tool. |
| `production-smoke.sh` | **Not a deployment tool — do not run it on a deploy host.** A `RAILS_ENV=production` boot smoke for one demo per unique HTML surface (`stylish` \| `prove`), catching the eager-load / proxy-CSRF / assistant-shaped-error classes that dev-mode CI cannot see. CI is its caller. It CREATES AND DROPS `kiosk_<app>_smoke`, so `require_disposable_host()` aborts outright when the box carries deploy markers (`/srv/kiosk`, `/etc/kiosk-demo`, an installed `kiosk-demo@.service`) and otherwise demands `CI` or `KIOSK_SMOKE_I_AM_DISPOSABLE=1` (K-594). |
| `CHECKLIST.md` | The tick-through version of this runbook — what an operator actually ticks off on deploy day, incl. the recorded skips. |
| `README.md` | This runbook. |

## Per-demo map

| Demo | Subdomain | Port | PoW difficulty | Stripe (test) |
|------|-----------|------|----------------|---------------|
| getgrocery | `getgrocery.demo.kiosk.tech` | 3001 | **low** (~1 s, poke-friendly) | yes |
| atablefor  | `atablefor.demo.kiosk.tech` | 3002 | **HIGH** (~9–10 s, "beware: intensive PoW") | — (no payment provider) |
| hoteling   | `hoteling.demo.kiosk.tech` | 3003 | **low** | — |
| skooti     | `skooti.demo.kiosk.tech` | 3004 | **low** | — |
| stylish    | `stylish.demo.kiosk.tech` | 3005 | **low** | — |
| philslist  | `philslist.demo.kiosk.tech` | 3006 | **low** | — |
| tudu       | `tudu.demo.kiosk.tech` | 3007 | **low** | — |
| prove (KYC broker) | `kyc.demo.kiosk.tech` | 3008 | — (not a Kiosk operator) | — |

**The KYC broker is the odd one out**: the gem dir is `kiosk-demo-prove` but it serves
`kyc.demo.kiosk.tech` and is an **ISSUER, not a Kiosk operator** — no PoW gate,
no `/.well-known/kiosk.json`, no agent surface, no payment provider. It depends
on no kiosk gem. Its env template is `env/kyc-demo.env.example` → copy to
`/etc/kiosk-demo/prove.env` (the systemd instance is `prove`, matching the dir);
its Caddy vhost is `kyc.demo.kiosk.tech → 127.0.0.1:3008`. skooti trusts it as
its KYC issuer (skooti's env pins `KIOSK_PROVE_*` at this broker).

**PoW difficulty is a feature**: ALL seven demos honor the
`KIOSK_POW_DIFFICULTY` knob (low default, high opt-in) in their env file. Six run
a low/fast toll so a poker can register in ~1 s and still SEE the toll; only
**atablefor** — the designated production-grade showcase — ships the high
memory+CPU-hard toll behind a "beware: intensive PoW" banner so the toll is
tangible first-hand. (The toll prices abuse; it is not by itself a DoS shield —
see "Edge rate-limit — REQUIRED" below.) Any other demo is knob-adjustable: set
`KIOSK_POW_DIFFICULTY=high` on it too to feel its own toll.

> **How it wires (WIRED).** All seven demos' initializers read
> `ENV["KIOSK_POW_DIFFICULTY"]` (`low` default, `high` opt-in) via
> `app/services/pow_difficulty.rb` and set their Equihash params accordingly:
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
> `{n,k}` — so an AI assistant/reader sees the toll up front. Env files ship
> only `atablefor` = `high` (the production-grade showcase); all six others =
> `low` (each still knob-adjustable to `high`).

## What the operator does vs. what's automated

**Operator (manual):**
1. **DNS.** Either a wildcard `*.demo.kiosk.tech → VPS_IP` (one A record, add
   apps later with no DNS change) or one A record per subdomain above.
2. **Provision the VPS** (2–4 GB; all 8 apps at the shipped `WEB_CONCURRENCY=1`
   × ~250 MB RSS ≈ 2 GB Puma, so 4 GB is comfortable once Postgres and Caddy
   take their share). Install Postgres 17, Caddy **with the `caddy-ratelimit`
   module** (see "Edge rate-limit — REQUIRED" below; stock Caddy has no
   rate-limiting), Ruby (`.mise.toml` pins the version), and a non-login `kiosk`
   service user.
3. **Set real secrets.** Replace every `REPLACE_*` value in each
   `env/<app>.env.example` (secret key base, DB passwords, signing key, PoW
   secret, a Stripe **test** key for getgrocery only). Copy to
   `/etc/kiosk-demo/<app>.env`, mode `0600`, owner `kiosk`. The templates are
   shell-source-safe as written, so `set -a; . file` works.
4. **Run the steps below**, or hand over shell access.

**Automated (this runbook provides):** the Caddy vhosts, the SQL to create all
DBs + roles, the systemd unit template, and the env templates. (Nothing in this
directory runs on a schedule — no cron, no timer — and nothing reclaims demo
accounts. `demo-reset.sh` is the disk-reclaim tool and you run it by hand; the
catalog re-seed is the push-to-deploy hook's job. See step 5.)
No app code changes are required to run multi-app/one-Postgres — each
demo already ships a production `database.yml` that reads its own DB + role from
its env file (see [Database names](#database-names)).

### Database names

Every app's production `database.yml` resolves its database and login role from
its env file, defaulting to the shipped names:

| env var (in `env/<app>.env`) | default | psql var for `postgres-init.sql` |
|------------------------------|---------|----------------------------------|
| `KIOSK_<APP>_DB`             | `kiosk_<app>_production` | `-v <xx>_db=` |
| `KIOSK_<APP>_DB_USER`        | `kiosk_<app>`            | `-v <xx>_user=` |
| `KIOSK_<APP>_DB_PASSWORD`    | — (required)             | `-v <xx>_pw=` |

`<xx>` is the two-letter prefix already used for the passwords: `gg` getgrocery ·
`af` atablefor · `ho` hoteling · `sk` skooti · `st` stylish · `pl` philslist ·
`td` tudu · `pv` prove.

Leave the names alone and there is nothing to do — the templates ship the
defaults and step 1 below provisions exactly those. **If you change a name, change
it in both places**: the app's env file *and* the matching `-v` on the
`postgres-init.sql` command line. psql cannot read the env files itself (they are
per-app and are sourced by systemd, not by the superuser shell running the init
script), so the two sides are kept in sync by hand. `demo-reset.sh` reads the env
file, so it follows an override on its own.

### Steps

```sh
# 0. Check the monorepo out AT /srv/kiosk (owned by the kiosk user) — the repo
#    ROOT is /srv/kiosk itself, not a subdirectory of it. So each app lives at
#    /srv/kiosk/kiosk-demo-<name> and this runbook's own files are at
#    /srv/kiosk/deploy/<file>. That is the layout the shipped units and scripts
#    hardcode: kiosk-demo@.service's WorkingDirectory=/srv/kiosk/kiosk-demo-%i
#    and demo-reset.sh's /srv/kiosk/deploy/demo-reset.sh.

# 1. Postgres: create the 8 DBs + least-privilege roles (7 demos + prove).
#    Pass each password as a plain psql variable — the RAW password, no quotes
#    (the script quote-escapes it safely via :'var').
#    Names default to the shipped ones; add -v <xx>_db= / -v <xx>_user= ONLY if
#    you changed KIOSK_<APP>_DB / _DB_USER in that app's env (see "Database
#    names" above).
sudo -u postgres psql -v ON_ERROR_STOP=1 \
  -v gg_pw=… -v af_pw=… -v ho_pw=… -v sk_pw=… \
  -v st_pw=… -v pl_pw=… -v td_pw=… -v pv_pw=… \
  -f /srv/kiosk/deploy/postgres-init.sql
#    Then set max_connections=100 in postgresql.conf and reload.

# 2. Per app: install gems, precompile assets, prepare the DB (schema + seed).
for app in getgrocery atablefor hoteling skooti stylish philslist tudu; do
  cd /srv/kiosk/kiosk-demo-$app
  bundle install
  set -a; . /etc/kiosk-demo/$app.env; set +a
  RAILS_ENV=production bin/rails assets:precompile db:prepare
done
#    db:prepare creates the schema, runs migrations (incl. the kiosk schema +
#    opt-in RLS), and seeds the shared catalog on first run.

# 2b. The KYC broker (kiosk-demo-prove; serves kyc.demo.kiosk.tech). It is
#     an ISSUER, not a Kiosk operator — no kiosk gem, no assets manifest — so
#     prepare it on its own (db:prepare only; assets:precompile is a no-op/absent).
cd /srv/kiosk/kiosk-demo-prove
bundle install
set -a; . /etc/kiosk-demo/prove.env; set +a   # from env/kyc-demo.env.example
RAILS_ENV=production bin/rails db:prepare

# 3. systemd: install the template unit and enable one instance per app.
sudo cp /srv/kiosk/deploy/kiosk-demo@.service /etc/systemd/system/
sudo mkdir -p /etc/kiosk-demo   # env files live here (Operator step #3)
sudo systemctl daemon-reload
for app in getgrocery atablefor hoteling skooti stylish philslist tudu prove; do
  sudo systemctl enable --now kiosk-demo@$app
done
#    Check: systemctl status kiosk-demo@getgrocery ; journalctl -u kiosk-demo@skooti -f


# 4. Caddy: install the edge rate-limit module, then point it at this Caddyfile.
#    Caddy fetches a cert per subdomain on first request (HTTP-01). For a single
#    wildcard cert instead, see the DNS-01 note in the Caddyfile header.

#    STEP 4a IS REQUIRED — see "Edge rate-limit" below. Skipping it leaves
#    /kiosk/auth/register as an unauthenticated CPU sink with nothing bounding
#    the request rate.
sudo caddy add-package github.com/mholt/caddy-ratelimit   # Caddy >= 2.7
sudo systemctl restart caddy
caddy list-modules | grep rate_limit                      # must print the module
sudo cp /srv/kiosk/deploy/Caddyfile /etc/caddy/Caddyfile
#    Now uncomment `import ratelimit` + the (ratelimit) snippet in
#    /etc/caddy/Caddyfile (they ship commented so a stock binary still boots).
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# 5. Housekeeping: NOTHING TO INSTALL. There is no cron and no timer here, and
#    nothing in this repo reclaims demo ACCOUNTS — on a schedule or otherwise.
#    No demo ships a retention task. The two jobs a nightly cron would have done
#    are each already covered by something you run or already ran:
#
#      * RE-SEEDING the shared catalog — the push-to-deploy hook does it, running
#        `db:seed` on every push (K-464). Every demo's seeds are idempotent and
#        additive (zero delete_all, verified live on all seven), so a push tops
#        the catalog up and deletes nothing.
#
#      * RECLAIMING DISK — deploy/demo-reset.sh, by hand on the box, when a demo
#        DB has grown from poking. On demand rather than nightly because the
#        demos are per-agent isolated: a poker's junk is invisible to the next
#        poker, so disk is the only cost it imposes.
```


## Edge rate-limit — REQUIRED (K-540)

**Proof-of-work does not remove the need for a limiter in front of the app; on
the register path it is the thing being exploited.** `POST /kiosk/auth/register`
runs the PoW gate **unauthenticated**, before any key verification: anyone can
take a free 402 challenge and resubmit it with a valid HMAC sig and garbage
indices, and each submission costs *this box* an Equihash verify (~19 ms
measured at `n=168 k=7`). PoW prices the attacker's **solve**; it does not price
our **verify**. At the shipped `WEB_CONCURRENCY=1`, ~54 req/s saturates a
worker — and a plain flood of any other endpoint does much the same.

The app-side half is already shipped (an issued challenge drives at most one
verify; structural pre-checks run before the hash loop). The operator-side half
is yours, and there is no app setting that substitutes for it. Pick one:

- **Caddy module** (what step 4 above does): `caddy add-package
  github.com/mholt/caddy-ratelimit` (Caddy ≥ 2.7 swaps in a plugin-included
  binary from the official download API — Caddy flags the subcommand
  EXPERIMENTAL, so `xcaddy build --with github.com/mholt/caddy-ratelimit` is the
  stable equivalent if you compile your own), then uncomment
  `import ratelimit` and the `(ratelimit)` snippet in the Caddyfile. They ship
  **commented** because `rate_limit` is not a stock directive — a stock binary
  refuses the whole config ("unrecognized directive: rate_limit") and would not
  start at all, which is why enabling it is a runbook step and not a default.
- **CDN / WAF** in front of the box (Cloudflare et al.) with a per-IP rate rule
  on `/kiosk/*`. Equally acceptable; then leave the Caddy snippet commented.

Deploying with **neither** is the one unacceptable option. Verify afterwards:
hammer `/kiosk/auth/register` from one IP and confirm you are cut off (429)
well before the box slows down.

## Scaling past one worker — shared stores REQUIRED (K-738)

Everything above assumes the shipped `WEB_CONCURRENCY=1`. Raising it (or putting
a second app host behind the balancer) changes one security property: the PoW
**spent-id set** is in-process by default, so single-use — which the protocol
states normatively (`protocol.md` §15.2, §16.1) — degrades to *once per worker*,
and N workers accept the same proof N times. The auth-challenge store is
in-process for the same reason, and breaks the register/login handshake outright
(challenge on worker A, redeem on worker B).

So before you raise the number: add the `pow_spent` table and set
`c.pow_spent_store = Kiosk::Server::PowSpentStores::ActiveRecord.new`, and give
`c.auth_challenge_store` a shared implementation. Both are ~5 lines in the
initializer — see kiosk-server's README, "Multi-process deployments". This is
the same class of operator obligation as the edge rate-limit above: the app
cannot do it for you.

## Payments — Stripe TEST mode

getgrocery (SetupIntent card-on-file) runs Stripe in **test mode** — it is the
only demo with a payment provider. A poker completes a real `off_session`
PaymentIntent end-to-end with **no real charge** and **no live key on the box**.
(atablefor books restaurant tables — a reservation takes no money, so it
configures **no** payment provider and `pay` is absent from its capabilities.)
Publish the test card on getgrocery's landing:

> **Test card:** `4242 4242 4242 4242` — any future expiry, any CVC, any ZIP.
> More cards: <https://docs.stripe.com/testing>

> **Card-setup Checkout can show "Something went wrong" if a relaying agent truncates the link (K-473).**
> `payment_setup` returns a valid Stripe `mode:setup` `setup_url` — a long
> `checkout.stripe.com/c/pay/<id>#fid…` whose ~500-char `#fid…` fragment Stripe REQUIRES to
> render. The failure is an AGENT relaying that url to the human and DROPPING the fragment (an
> LLM truncating a long opaque string; proven from a live agent's message store) — NOT our code,
> the session, or the Stripe account (deploy and local dev share one account; the session is a
> valid `status:open`). Mitigation: the agent skill instructs assistants to relay the `setup_url`
> VERBATIM and in full, never truncating the part after `#`. If truncation still recurs, the
> robust escalation is an operator-hosted short redirect link (a ready alternative — see K-473).

## Poke it — the "curl one-liner"

Three documents are always free: the top-level **discovery** document, and the
two catalogue documents `GET /kiosk/schema` and `GET /kiosk/openapi.json` — no
Bearer, no toll, and `Cache-Control: max-age=60, public` so a poker (or an
assistant) can read what the origin offers before it registers. Everything else
— every query, every action, `pay` — needs a Bearer token and MAY toll
proof-of-work, and so may `register`. So the register gate is a memory-hard PoW
by design, and the "true" one-liner ships a copy-paste **solver**
(`kiosk-pow-equihash/solve.py`). Hosted difficulty is low (~1 s) on six demos;
atablefor is intentionally ~9–10 s (you'll feel it — that's the point). Flow:
**discover (free) → read the schema (free) → register (solve PoW) → call a verb
(each MAY toll PoW too)**.

```sh
# 0. Discover: who/where/which capabilities. Free — no auth, no PoW, same as the
#    schema in step (d). (The queries and actions in (e)/(f) are NOT free: each
#    needs a Bearer token and MAY answer 402 pow_required — solve and retry.)
curl -s https://getgrocery.demo.kiosk.tech/.well-known/kiosk.json | jq .

# 1. Full flow — register with the bundled solver, then read schema + query.
BASE=https://getgrocery.demo.kiosk.tech

#    a) get a register challenge (returns the Equihash params to solve)
CH=$(curl -s "$BASE/kiosk/auth/challenge")

#    b) solve it with the bundled solver (from kiosk-pow-equihash/):
#       python3 solve.py  reads the challenge on stdin, prints the proof.
PROOF=$(echo "$CH" | python3 kiosk-pow-equihash/solve.py)   # ~1 s low / ~9–10 s high (atablefor)

#    c) register (agent key + solved proof) → returns a token
TOKEN=$(curl -s -X POST "$BASE/kiosk/auth/register" \
  -H 'content-type: application/json' \
  -d "$PROOF" | jq -r .token)

#    d) read the schema — PUBLIC and cacheable, so no Bearer and no toll here;
#       this one answers just as well before step (c) as after it.
curl -s "$BASE/kiosk/schema" | jq .

#    e) call a query as the registered assistant — protocol 0.4: one endpoint
#       per verb, a query is a GET whose arguments are the query string, and the
#       success body IS the result: a bare JSON array, no envelope to unwrap
#       (the matching-row count rides in the X-Total-Count response header).
#       Bearer required, MAY 402 — solve like register and re-send the SAME
#       request with the proof in the Kiosk-PoW header.
curl -s "$BASE/kiosk/catalog" \
  -H "authorization: Bearer $TOKEN" | jq .

#    f) …and an action is a POST at its own path, with the arguments as the body.
#       Send everything the verb's input_schema requires — create_order needs
#       delivery_slot_id and delivery_address as well as items (delivery is part
#       of the order), and a call missing one is a typed 400 naming it. The
#       slot id is a `delivery_slot_id` from the delivery_slots query;
#       delivery_date is optional and omitting it books tomorrow.
curl -s -X POST "$BASE/kiosk/create_order" \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"items":[{"sku":"milk-0.5l","qty":2}],
       "delivery_slot_id":3,
       "delivery_address":"42 Camden Street, Dublin 2"}' | jq .
```

> The exact challenge/proof JSON shape is what the demo's `/kiosk/auth/challenge`
> returns and `solve.py` consumes — publish the copy-paste-exact snippet on each
> demo landing once the hosted challenge format is pinned. atablefor shows the
> "beware: memory- and CPU-intensive PoW" banner so pokers expect the ~9–10 s.

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
and landing tile return. It also runs in CI against the job's throwaway
database, so seeding the SHARED store is deliberate rather than incidental: with
`KIOSK_TELEMETRY_DB_URL` set the task ABORTS unless you also pass
`SEED_SHARED=1` (K-620). To seed the hosted store:

    KIOSK_TELEMETRY_DB_URL=postgres://kiosk_telemetry:<pw>@127.0.0.1/kiosk_demo_telemetry \
      SEED_SHARED=1 bundle exec rake demo:telemetry

Those rows are SYNTHETIC and indistinguishable from real activity in the
aggregate — seed once before launch, not after there is traffic to report.

Housekeeping of this store is manual: the aggregates look back 10 min / 1 h /
all-time-registered, so rows past the registered-count horizon can be trimmed to
reclaim disk. Nothing does it for you — `kiosk_telemetry` is granted only SELECT
and INSERT, so a trim is a DB-owner/superuser `DELETE`, run by hand.
