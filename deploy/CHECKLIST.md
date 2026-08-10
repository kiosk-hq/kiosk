# Deploy checklist — hosted demos on kiosk.tech subdomains

Concise, ordered. Detail + file contents: `deploy/README.md`. Operator actions.
Seven demos: getgrocery · atablefor · hoteling · skooti · stylish · philslist · tudu.
Plus the prove.my KYC broker (`kiosk-demo-prove` → `kyc.demo.kiosk.tech`, port 3008) —
an ISSUER, not a Kiosk operator (no PoW, no `/.well-known/kiosk.json`, no agent surface).

## 1. DNS (you)
- [ ] Wildcard `*.demo.kiosk.tech` → VPS_IP (one A record; add apps without DNS changes).
      Or per-app A records (`getgrocery.demo.kiosk.tech`, …). Optionally `atablefor.us` apex.

## 2. Provision the VPS (one small box, ~2–4 GB)
- [ ] Install: **Caddy**, **PostgreSQL** (17 preferred; on 16 strip the one `SET transaction_timeout`
      line from each `structure.sql` — it is the only PG17-ism), **Ruby 4.0.1** via **mise**, git.
- [ ] **No Python/numpy needed on the server** — it only *verifies* proofs (cheap, pure Ruby). numpy is
      the client's *solver* (`solve.py`); install it on the box ONLY if you want to run the solve-side
      demo smoke tests (`demo:shop`/`demo:book`/`demo:backoff`) there.
- [ ] **Lean Puma** for a small box: `WEB_CONCURRENCY=1` (or 0) + `RAILS_MAX_THREADS=5` per app —
      what every `deploy/env/*.env.example` already ships, so a copied template needs no edit here.
- [ ] `git clone` the reference repo (or push-to-deploy — see §7).

## 3. Databases (one Postgres cluster)
- [ ] `psql -v gg_pw=… -v af_pw=… -v ho_pw=… -v sk_pw=… -v st_pw=… -v pl_pw=… -v td_pw=… -v pv_pw=… -f deploy/postgres-init.sql`  → 8 app DBs + least-priv roles (7 demos + `kiosk_prove`). (Pass each RAW password unquoted — the script escapes it via `:'var'`.)
- [ ] **Only if you renamed something:** the DB/role names default to the shipped ones. If you changed `KIOSK_<APP>_DB` / `KIOSK_<APP>_DB_USER` in an app's env (§4), pass the SAME value here as `-v <xx>_db=` / `-v <xx>_user=` (`gg af ho sk st pl td pv`) — otherwise provisioning creates one name and the app connects to another. See `deploy/README.md` §"Database names".
- [ ] `psql -v tm_pw=… -f deploy/telemetry-init.sql`  → the shared `kiosk_demo_telemetry` DB + role.

## 4. Per-app env (copy `deploy/env/<app>.env.example` → real values)
For EACH of the 7 apps:
- [ ] `RAILS_ENV=production`, a generated `SECRET_KEY_BASE`, `PGHOST`, `KIOSK_<APP>_DB` / `KIOSK_<APP>_DB_{USER,PASSWORD}`, `PORT` (3001–3007). `KIOSK_<APP>_DB` and `KIOSK_<APP>_DB_USER` default to `kiosk_<app>_production` / `kiosk_<app>` — keep the shipped values and §3 needs no extra flags.
- [ ] **Issuer + signing key (all 7 demos):** `KIOSK_ISSUER` (K-510) and `KIOSK_SIGNING_KEY_B64` are crash-if-absent
      outside dev/test — the app refuses to boot without them, and so does `zeitwerk:check` in §5. The example ships
      `KIOSK_ISSUER=https://<app>.demo.kiosk.tech`: **change it if you serve a different origin**, because it is the `aud`
      every assistant proof is checked against — a wrong value rejects every assistant with "proof audience mismatch"
      rather than failing loudly at boot.
- [ ] **PoW:** all 7 demos honor `KIOSK_POW_DIFFICULTY` (low default, high opt-in). Ship `high` for **atablefor** only
      (n=168/k=7, ~9–10 s / ~1.3 GiB, "beware" banner) — the production-grade showcase; `low` (or unset) for the other six
      (fast, poke-friendly; each still knob-adjustable to `high`).
- [ ] **PoW mode (atablefor, K-497):** the flagship advertises the **reputation** anti-scalping policy — its env ships
      `KIOSK_POW_MODE=reputation` (RateAndReputation with the real confirmed-bookings factor). ONE explicit selector replaces
      the old mutually-overriding `KIOSK_POW_DEMO` / `KIOSK_POW_REPUTATION_DEMO` / `KIOSK_POW_BACKOFF_DEMO` flags — drop them
      (setting more than one now RAISES at boot). At `high` a fresh visitor pays its reputation count of ~2 proofs (~20 s) at
      first contact, dropping to 1 then a free pass as its bookings confirm (K-517=b). Other modes: `demo` / `backoff` / `off`.
- [ ] **PoW secret (all 7 demos, K-541):** set `KIOSK_POW_SECRET=$(openssl rand -hex 32)` — REQUIRED; the app refuses to boot
      without it outside dev/test (a shipped default would be world-readable in the public repo, letting anyone forge a
      trivial-difficulty challenge and turn PoW off). Must be ≥ 32 bytes.
- [ ] **Telemetry:** `KIOSK_TELEMETRY=1`, `KIOSK_TELEMETRY_DB_URL=postgres://kiosk_telemetry:…@…/kiosk_demo_telemetry`,
      and a **distinct** `KIOSK_TELEMETRY_SALT=<random>` per app (keeps the per-app agent hashes non-joinable).
- [ ] **Stripe (getgrocery only):** `STRIPE_SECRET_KEY=sk_test_…` (TEST mode — no real charges). getgrocery is the only demo with a payment provider; atablefor takes no money (no `pay` capability).
- [ ] **Card-setup Checkout render (getgrocery, K-473):** `payment_setup`'s `setup_url` is a valid Stripe link, but a relaying agent can truncate its required `#fid…` fragment → **"Something went wrong"** (not the account/deploy — the session is valid; proven agent-side). Mitigated by skill guidance (relay the url verbatim/in full); escalate to an operator-hosted short redirect if it recurs. See `deploy/README.md` §Payments.

### 4b. prove.my KYC broker env (copy `deploy/env/kyc-demo.env.example` → `/etc/kiosk-demo/prove.env`)
- [ ] `SECRET_KEY_BASE`, `KIOSK_PROVE_DB` / `KIOSK_PROVE_DB_{USER,PASSWORD}`, `PORT=3008`. No kiosk gem — no signing key / no PoW knob.
- [ ] **Issuer + public URL:** `KIOSK_PROVE_ISSUER=https://kyc.demo.kiosk.tech`, `PROVE_PUBLIC_URL=https://kyc.demo.kiosk.tech`.
- [ ] **Broker signing key:** `PROVE_KEY_PEM=<fresh 2048-bit RSA private PEM>` (do NOT ship the baked-in dev key).
- [ ] **Operator allow-list:** `KIOSK_PROVE_SKOOTI_SECRET=<shared intake secret>`, `KIOSK_PROVE_SKOOTI_CALLBACK_HOST=skooti.demo.kiosk.tech`.
- [ ] **Wire skooti to it:** in skooti's env set `KIOSK_PROVE_ISSUER` + `KIOSK_PROVE_BROKER_URL` = `https://kyc.demo.kiosk.tech`, the SAME `KIOSK_PROVE_SKOOTI_SECRET`, and `KIOSK_PROVE_PUBLIC_KEY_PEM=<public half of PROVE_KEY_PEM>` (or fetch once from `https://kyc.demo.kiosk.tech/prove_key.pem`).

## 5. Build + boot each app
- [ ] **Eager-load gate FIRST, on every changed app (K-488/K-513):**
      ```
      RAILS_ENV=production SECRET_KEY_BASE=throwaway \
        KIOSK_POW_SECRET=throwaway-at-least-32-bytes-long-xxxx \
        KIOSK_ISSUER=https://throwaway.example.test \
        bin/rails zeitwerk:check                     # getgrocery: add STRIPE_SECRET_KEY=sk_test_throwaway
      ```
      It eager-loads the whole app the way production does and exits non-zero on the first constant/path mismatch — the
      class that 502'd three demos in the K-487 deploy, invisible to every dev-mode gate. Needs no database (it loads
      code, it does not connect). Every value here is a throwaway: nothing is signed, served or dialed.
      The three env vars are not optional decoration — each is crash-if-absent in `production`, and a missing one aborts
      in the initializer BEFORE Zeitwerk runs, so the command exits 1 for a reason that has nothing to do with eager
      loading (`KIOSK_POW_SECRET` K-541, `KIOSK_ISSUER` K-510, getgrocery's Stripe key/mock URL). Verified on all 8 apps.
      CI runs the same gate for all 8 apps on every push, so a green CI on the exact commit you are deploying is the same
      gate; run it by hand whenever you deploy a tree CI has not seen. **If an initializer ever learns to raise outside
      dev/test, add the variable HERE and in `.github/workflows/ci.yml` in the same commit** — these two are one gate
      written twice, and this copy is the one a human types.
- [ ] `bundle install` · `RAILS_ENV=production bin/rails assets:precompile db:prepare` · `bin/rails demo:setup` (seed).
- [ ] Enable the systemd unit: `systemctl enable --now kiosk-demo@<app>` (per `deploy/kiosk-demo@.service`, binds 127.0.0.1:<port>).

## 6. Front with Caddy (auto-TLS)
- [ ] **Edge rate-limit module — REQUIRED, do this BEFORE installing the Caddyfile (K-540):**
      `sudo caddy add-package github.com/mholt/caddy-ratelimit` (Caddy ≥ 2.7 swaps in a plugin-included
      binary; `xcaddy build --with github.com/mholt/caddy-ratelimit` is the stable equivalent if you compile
      your own) · `sudo systemctl restart caddy` · confirm with `caddy list-modules | grep rate_limit`.
      A stock Caddy has **no** rate-limiting at all, and `POST /kiosk/auth/register` runs the PoW gate
      UNAUTHENTICATED — PoW prices the attacker's *solve*, not our *verify* (~19 ms each), so at the shipped
      `WEB_CONCURRENCY=1` roughly 54 req/s saturate a worker. Nothing in the app substitutes for this.
      **Acceptable alternative:** a per-IP rate rule on `/kiosk/*` at a CDN/WAF in front of the box — then
      skip the module and leave the Caddy snippet commented. Deploying with **neither** is the one
      unacceptable option. Detail: `deploy/README.md` §"Edge rate-limit — REQUIRED".
- [ ] Install `deploy/Caddyfile` (**8** vhosts → loopback ports: getgrocery/atablefor/hoteling/skooti/
      stylish/philslist/tudu + `kyc` for the prove.my broker). Certs issue automatically.
- [ ] **Uncomment the rate-limit (only after the module is installed):** in `/etc/caddy/Caddyfile` uncomment
      `import ratelimit` inside `(kioskproxy)` AND the whole `(ratelimit)` snippet. They ship **commented**
      because `rate_limit` is not a stock directive — a stock binary refuses the WHOLE config
      ("unrecognized directive: rate_limit", verified on Caddy v2.11.2) and then no site serves at all.
      Then `sudo caddy validate --config /etc/caddy/Caddyfile` · `sudo systemctl reload caddy`.
- [ ] Verify the limit bites: hammer `/kiosk/auth/register` from one IP and confirm 429 well before the box slows.
- [ ] ⚠ On the CURRENT live box the `/etc/caddy/Caddyfile` is hand-maintained and also serves other sites —
      do NOT overwrite it with `deploy/Caddyfile` (you would drop the other vhosts). Hand-add the blocks in its
      style instead. See the DRIFT NOTE (K-463) in the Caddyfile header.

## 7. Deploy new code (push-to-deploy) + housekeeping
- [ ] **git push-to-deploy** (mirrors narrathon): a bare repo per box with an ISOLATED `post-receive` hook
      (own work-tree/service names/deploy user — never touches `/opt/narrathon`) that checks out `main`,
      `bundle install`, `db:prepare`, and restarts each app's service.
- [ ] ~~Prune cron~~ — **SKIPPED** (Phil): not essential; reseed a bloated demo DB by hand if ever needed
      (`deploy/demo-reset.sh`). `deploy/prune.sh` stays in the repo as an available-but-uninstalled tool —
      `deploy/README.md` step 5 documents the crontab line for anyone who does want it. Nothing installs it.

## 8. Verify (per subdomain)
- [ ] `GET https://<app>.demo.kiosk.tech/.well-known/kiosk.json` returns discovery (atablefor shows the "beware" PoW notice).
- [ ] The demo **root page** loads (what it is + a curl one-liner + the live activity counters).
- [ ] `GET https://<app>.demo.kiosk.tech/demo/activity.json` returns aggregates.
- [ ] getgrocery: a Stripe test card `4242 4242 4242 4242` completes a real test-mode pay (the only demo with a payment provider).
- [ ] prove.my broker: `GET https://kyc.demo.kiosk.tech/` renders the human explainer (STUB-KYC notice; NO agent/kiosk signal); `GET /prove_key.pem` returns the public key; `GET /.well-known/kiosk.json` is **absent** (404 — it is an issuer, not an operator).

## Notes
- Everything is OFF by default in code — nothing here changes local/CI behavior.
- Test card + Stripe testing docs: https://docs.stripe.com/testing
