# Deploy checklist — hosted demos on kiosk.tech subdomains

Concise, ordered. Detail + file contents: `deploy/README.md`. Operator actions.
Seven demos: getgrocery · atablefor · hoteling · skooti · stylish · philslist · tudu.

## 1. DNS (you)
- [ ] Wildcard `*.demo.kiosk.tech` → VPS_IP (one A record; add apps without DNS changes).
      Or per-app A records (`getgrocery.demo.kiosk.tech`, …). Optionally `atablefor.us` apex.

## 2. Provision the VPS (one small box, ~2–4 GB)
- [ ] Install: **Caddy**, **PostgreSQL** (17 preferred; on 16 strip the one `SET transaction_timeout`
      line from each `structure.sql` — it is the only PG17-ism), **Ruby 4.0.1** via **mise**, git.
- [ ] **No Python/numpy needed on the server** — it only *verifies* proofs (cheap, pure Ruby). numpy is
      the client's *solver* (`solve.py`); install it on the box ONLY if you want to run the solve-side
      demo smoke tests (`demo:shop`/`demo:book`/`demo:backoff`) there.
- [ ] **Lean Puma** for a small box: `WEB_CONCURRENCY=1` (or 0) + `RAILS_MAX_THREADS=5` per app.
- [ ] `git clone` the reference repo (or push-to-deploy — see §7).

## 3. Databases (one Postgres cluster)
- [ ] `psql -v pw_getgrocery="'…'" … -f deploy/postgres-init.sql`  → 7 app DBs + least-priv roles.
- [ ] `psql -v tm_pw="'…'" -f deploy/telemetry-init.sql`  → the shared `kiosk_demo_telemetry` DB + role.

## 4. Per-app env (copy `deploy/env/<app>.env.example` → real values)
For EACH of the 7 apps:
- [ ] `RAILS_ENV=production`, a generated `SECRET_KEY_BASE`, `KIOSK_<APP>_DB_{HOST,NAME,USER,PASSWORD}`, `PORT` (3001–3007).
- [ ] **PoW:** all 7 demos honor `KIOSK_POW_DIFFICULTY` (low default, high opt-in). Ship `high` for **atablefor** only
      (n=168/k=7, ~9–10 s / ~1.3 GiB, "beware" banner) — the production-grade showcase; `low` (or unset) for the other six
      (fast, poke-friendly; each still knob-adjustable to `high`).
- [ ] **PoW backoff (atablefor):** the flagship's env ships `KIOSK_POW_BACKOFF_DEMO=10` — the value is the free-call count,
      so one ~9 s solve buys the next 10 ungated calls (pokeable, still anti-scalping; it's the active reputation policy).
      Only atablefor is wired for it today; the six low-PoW demos solve sub-second so they don't need it.
      **If `WEB_CONCURRENCY>1`, the default in-process count is per-worker — pass a shared BackoffStore (Redis/DB) for an authoritative count, or run atablefor single-worker.**
- [ ] **Telemetry:** `KIOSK_TELEMETRY=1`, `KIOSK_TELEMETRY_DB_URL=postgres://kiosk_telemetry:…@…/kiosk_demo_telemetry`,
      and a **distinct** `KIOSK_TELEMETRY_SALT=<random>` per app (keeps the per-app agent hashes non-joinable).
- [ ] **Stripe (getgrocery + atablefor only):** `STRIPE_SECRET_KEY=sk_test_…` (TEST mode — no real charges).

## 5. Build + boot each app
- [ ] `bundle install` · `RAILS_ENV=production bin/rails assets:precompile db:prepare` · `bin/rails demo:setup` (seed).
- [ ] Enable the systemd unit: `systemctl enable --now kiosk-demo@<app>` (per `deploy/kiosk-demo@.service`, binds 127.0.0.1:<port>).

## 6. Front with Caddy (auto-TLS)
- [ ] Install `deploy/Caddyfile` (7 vhosts → loopback ports), `caddy reload`. Certs issue automatically.

## 7. Deploy new code (push-to-deploy) + housekeeping
- [ ] **git push-to-deploy** (mirrors narrathon): a bare repo per box with an ISOLATED `post-receive` hook
      (own work-tree/service names/deploy user — never touches `/opt/narrathon`) that checks out `main`,
      `bundle install`, `db:prepare`, and restarts each app's service.
- [ ] ~~Prune cron~~ — **SKIPPED** (Phil): not essential; reseed a bloated demo DB by hand if ever needed.

## 8. Verify (per subdomain)
- [ ] `GET https://<app>.demo.kiosk.tech/.well-known/kiosk.json` returns discovery (atablefor shows the "beware" PoW notice).
- [ ] The demo **root page** loads (what it is + a curl one-liner + the live activity counters).
- [ ] `GET https://<app>.demo.kiosk.tech/demo/activity.json` returns aggregates.
- [ ] getgrocery/atablefor: a Stripe test card `4242 4242 4242 4242` completes a real test-mode pay.

## Notes
- Everything is OFF by default in code — nothing here changes local/CI behavior.
- Test card + Stripe testing docs: https://docs.stripe.com/testing
