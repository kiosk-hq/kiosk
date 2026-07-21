# Deploy checklist — hosted demos on kiosk.tech subdomains

Concise, ordered. Detail + file contents: `deploy/README.md`. Operator actions.
Seven demos: getgrocery · atablefor · hoteling · skooti · stylish · philslist · tudu.

## 1. DNS (you)
- [ ] Wildcard `*.demo.kiosk.tech` → VPS_IP (one A record; add apps without DNS changes).
      Or per-app A records (`getgrocery.demo.kiosk.tech`, …). Optionally `atablefor.us` apex.

## 2. Provision the VPS (one small box, ~4 GB)
- [ ] Ubuntu; install: **Caddy**, **PostgreSQL 17** (the `structure.sql` are PG17-format),
      **Ruby 4.0.1** (mise), **Python 3 + numpy** (the Equihash solver needs it), git.
- [ ] `git clone` the reference repo (or deploy a checkout per app).

## 3. Databases (one Postgres cluster)
- [ ] `psql -v pw_getgrocery="'…'" … -f deploy/postgres-init.sql`  → 7 app DBs + least-priv roles.
- [ ] `psql -v tm_pw="'…'" -f deploy/telemetry-init.sql`  → the shared `kiosk_demo_telemetry` DB + role.

## 4. Per-app env (copy `deploy/env/<app>.env.example` → real values)
For EACH of the 7 apps:
- [ ] `RAILS_ENV=production`, a generated `SECRET_KEY_BASE`, `KIOSK_<APP>_DB_{HOST,NAME,USER,PASSWORD}`, `PORT` (3001–3007).
- [ ] **PoW:** `KIOSK_POW_DIFFICULTY=high` for **skooti** + **atablefor** (n=168/k=7, ~9–10 s / ~1.3 GiB, "beware" banner);
      `low` (or unset) for the other five (fast, poke-friendly).
- [ ] **Telemetry:** `KIOSK_TELEMETRY=1`, `KIOSK_TELEMETRY_DB_URL=postgres://kiosk_telemetry:…@…/kiosk_demo_telemetry`,
      and a **distinct** `KIOSK_TELEMETRY_SALT=<random>` per app (keeps the per-app agent hashes non-joinable).
- [ ] **Stripe (getgrocery + atablefor only):** `STRIPE_SECRET_KEY=sk_test_…` (TEST mode — no real charges).

## 5. Build + boot each app
- [ ] `bundle install` · `RAILS_ENV=production bin/rails assets:precompile db:prepare` · `bin/rails demo:setup` (seed).
- [ ] Enable the systemd unit: `systemctl enable --now kiosk-demo@<app>` (per `deploy/kiosk-demo@.service`, binds 127.0.0.1:<port>).

## 6. Front with Caddy (auto-TLS)
- [ ] Install `deploy/Caddyfile` (7 vhosts → loopback ports), `caddy reload`. Certs issue automatically.

## 7. Housekeeping
- [ ] Cron `deploy/prune.sh` daily (prune old anonymous accounts + reseed the shared catalog).

## 8. Verify (per subdomain)
- [ ] `GET https://<app>.demo.kiosk.tech/.well-known/kiosk.json` returns discovery (skooti/atablefor show the "beware" PoW notice).
- [ ] The demo **root page** loads (what it is + a curl one-liner + the live activity counters).
- [ ] `GET https://<app>.demo.kiosk.tech/demo/activity.json` returns aggregates.
- [ ] getgrocery/atablefor: a Stripe test card `4242 4242 4242 4242` completes a real test-mode pay.

## Notes
- Everything is OFF by default in code — nothing here changes local/CI behavior.
- Test card + Stripe testing docs: https://docs.stripe.com/testing
