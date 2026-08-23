# Deploy checklist — hosted demos on kiosk.tech subdomains

Concise, ordered. Detail + file contents: `deploy/README.md`. Operator actions.
Seven demos: getgrocery · atablefor · hoteling · skooti · stylish · philslist · tudu.
Plus the KYC broker (`kiosk-demo-prove` → `kyc.demo.kiosk.tech`, port 3008) —
an ISSUER, not a Kiosk operator (no PoW, no `/.well-known/kiosk.json`, no agent surface).

## 1. DNS (you)
- [ ] Wildcard `*.demo.kiosk.tech` → VPS_IP (one A record; add apps without DNS changes).
      Or per-app A records (`getgrocery.demo.kiosk.tech`, …).

## 2. Provision the VPS (one small box, ~2–4 GB)
- [ ] Install: **Caddy**, **PostgreSQL** (17 preferred; on 16 strip the one `SET transaction_timeout`
      line from each `structure.sql` — it is the only PG17-ism), **Ruby 4.0.1** via **mise**, git.
- [ ] **No Python/numpy needed on the server** — it only *verifies* proofs (cheap, pure Ruby). numpy is
      the client's *solver* (`solve.py`); install it on the box ONLY if you want to run the solve-side
      demo smoke tests (`demo:shop`/`demo:book`/`demo:backoff`) there.
- [ ] **Lean Puma** for a small box: `WEB_CONCURRENCY=1` (or 0) + `RAILS_MAX_THREADS=5` per app —
      what every `deploy/env/*.env.example` already ships, so a copied template needs no edit here.
- [ ] **If you raise `WEB_CONCURRENCY` above 1**, the PoW spent-id store and the auth-challenge store
      must be shared across workers first — both default to in-process, so PoW single-use degrades to
      once-per-worker and the auth handshake breaks. See kiosk-server's README,
      "Multi-process deployments". Nothing else on this list changes.
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
- [ ] ⚠ **UPGRADING AN EXISTING BOX — run `deploy/box-prep-2026-08-11.sh` BEFORE the first `prod-demo` deploy (K-509/K-540):**
      ```
      ssh <deploy-user>@<box> 'sudo bash -s' < reference/deploy/box-prep-2026-08-11.sh
      ```
      The `/etc/kiosk-demo/*.env` files are hand-maintained and no repo file drives them, so an env that predates
      the K-497 flag collapse still sets `KIOSK_POW_DEMO` / `KIOSK_POW_REPUTATION_DEMO` / `KIOSK_POW_BACKOFF_DEMO`,
      which current code **REFUSES at boot** — deploying first takes that app down. The script drops those and the
      long-dead `KIOSK_POW_REGISTER_DEMO` (nothing has read it since K-487; register PoW is unconditional via
      `c.registration_pow_count = 1`). A FRESH box built from this checklist needs none of it — the examples in
      `deploy/env/` are already clean. Nothing else instructs an operator to run this script, which is why the
      line is here: the fix has been committed and unrun since 2026-08-11.
- [ ] **PoW secret (all 7 demos, K-541):** set `KIOSK_POW_SECRET=$(openssl rand -hex 32)` — REQUIRED; the app refuses to boot
      without it outside dev/test (a shipped default would be world-readable in the public repo, letting anyone forge a
      trivial-difficulty challenge and turn PoW off). Must be ≥ 32 bytes.
- [ ] **Rental-token signing key (skooti only, K-686):** set `KIOSK_UNLOCK_SIGNING_KEY_PEM="$(openssl genpkey -algorithm ed25519)"`
      — REQUIRED, enforced at boot: skooti refuses to start in production without it (and rejects a value that does not
      parse as an Ed25519 **private** key), because the dev keypair it used to sign with unconditionally ships in this
      public repo — anyone with a clone could mint an unlock token every provisioned lock accepts, past reserve, payment,
      ownership and KYC. Provision/flash the locks with the matching public half
      (`openssl pkey -in key.pem -pubout -outform DER | tail -c 32 | xxd -p -c 32`); any lock still carrying the old
      repo key (`8857880d…`) must be reflashed. The other six operator demos have no locks and need nothing here.
- [ ] **Telemetry:** `KIOSK_TELEMETRY=1`, `KIOSK_TELEMETRY_DB_URL=postgres://kiosk_telemetry:…@…/kiosk_demo_telemetry`,
      and a **distinct** `KIOSK_TELEMETRY_SALT=<random>` per app (keeps the per-app agent hashes non-joinable).
- [ ] **Stripe (getgrocery only):** `STRIPE_SECRET_KEY=sk_test_…` (TEST mode — no real charges). getgrocery is the only demo with a payment provider; atablefor takes no money (no `pay` capability).
- [ ] **Card-setup Checkout render (getgrocery, K-473):** `payment_setup`'s `setup_url` is a valid Stripe link, but a relaying agent can truncate its required `#fid…` fragment → **"Something went wrong"** (not the account/deploy — the session is valid; proven agent-side). Mitigated by skill guidance (relay the url verbatim/in full); escalate to an operator-hosted short redirect if it recurs. See `deploy/README.md` §Payments.

### 4b. KYC broker env (copy `deploy/env/kyc-demo.env.example` → `/etc/kiosk-demo/prove.env`)
- [ ] `SECRET_KEY_BASE`, `KIOSK_PROVE_DB` / `KIOSK_PROVE_DB_{USER,PASSWORD}`, `PORT=3008`. No kiosk gem — no signing key / no PoW knob.
- [ ] **Issuer + public URL:** `KIOSK_PROVE_ISSUER=https://kyc.demo.kiosk.tech`, `PROVE_PUBLIC_URL=https://kyc.demo.kiosk.tech`.
- [ ] **Broker signing key:** `PROVE_KEY_PEM=<fresh 2048-bit RSA private PEM>` — REQUIRED, enforced at boot (K-673): the
      broker refuses to start in production without it (and rejects a PEM that does not parse as a private key), because
      the baked-in dev key's private half is world-readable in the public repo — silently signing with it would let anyone
      forge attestations, and the pin flows below would faithfully pin its forgeable public half.
- [ ] **Operator allow-list:** `KIOSK_PROVE_SKOOTI_SECRET=<shared intake secret>`, `KIOSK_PROVE_SKOOTI_CALLBACK_HOST=skooti.demo.kiosk.tech`.
- [ ] **Wire skooti to it:** in skooti's env set `KIOSK_PROVE_ISSUER` + `KIOSK_PROVE_BROKER_URL` = `https://kyc.demo.kiosk.tech`, `KIOSK_PROVE_INTAKE_SECRET=<the SAME value as the broker's KIOSK_PROVE_SKOOTI_SECRET>`, and `KIOSK_PROVE_PUBLIC_KEY_PEM=<public half of PROVE_KEY_PEM>` (or fetch once from `https://kyc.demo.kiosk.tech/prove_key.pem`).
      The names differ by design (K-694): every OPERATOR app reads one role-named `KIOSK_PROVE_INTAKE_SECRET` — their
      `config/environments/production.rb` is byte-identical across the seven demos and so must not name a demo — while
      the BROKER keeps a per-operator name for each registry entry. The two sides pair by VALUE; the broker resolves the
      operator from the `operator_id` in the intake body. Same for getgrocery when it is allow-listed
      (`KIOSK_PROVE_GETGROCERY_SECRET` at the broker ↔ `KIOSK_PROVE_INTAKE_SECRET` in getgrocery's env).

## 5. Build + boot each app
- [ ] **Eager-load gate FIRST, on every changed app (K-488/K-513):**
      ```
      RAILS_ENV=production SECRET_KEY_BASE=throwaway \
        KIOSK_POW_SECRET=throwaway-at-least-32-bytes-long-xxxx \
        KIOSK_ISSUER=https://throwaway.example.test \
        bin/rails zeitwerk:check                     # getgrocery: add STRIPE_SECRET_KEY=sk_test_throwaway
                                                     # prove: add PROVE_KEY_PEM="$(openssl genrsa 2048)" — it must PARSE
                                                     #   as an RSA private key (K-673), a throwaway literal will not do;
                                                     #   the kiosk vars above are ignored by the broker (harmless)
                                                     # skooti: add KIOSK_UNLOCK_SIGNING_KEY_PEM="$(openssl genpkey \
                                                     #   -algorithm ed25519)" — same rule, it must PARSE as an Ed25519
                                                     #   PRIVATE key (K-686)
      ```
      It eager-loads the whole app the way production does and exits non-zero on the first constant/path mismatch — the
      class that 502'd three demos in the K-487 deploy, invisible to every dev-mode gate. Needs no database (it loads
      code, it does not connect). Every value here is a throwaway: nothing is signed, served or dialed.
      The three env vars are not optional decoration — each is crash-if-absent in `production`, and a missing one aborts
      in the initializer BEFORE Zeitwerk runs, so the command exits 1 for a reason that has nothing to do with eager
      loading (`KIOSK_POW_SECRET` K-541, `KIOSK_ISSUER` K-510, getgrocery's Stripe key/mock URL, the broker's
      `PROVE_KEY_PEM` K-673, skooti's `KIOSK_UNLOCK_SIGNING_KEY_PEM` K-686). Verified on all 8 apps.
      CI runs the same gate for all 8 apps on every push, so a green CI on the exact commit you are deploying is the same
      gate; run it by hand whenever you deploy a tree CI has not seen. **If an initializer ever learns to raise outside
      dev/test, add the variable HERE and in `.github/workflows/ci.yml` in the same commit** — these two are one gate
      written twice, and this copy is the one a human types.
- [ ] `bundle install` · `RAILS_ENV=production bin/rails assets:precompile db:prepare` · `bin/rails demo:setup` (seed).
- [ ] ⚠ **hoteling only, and ONLY on a database that already holds bookings (K-690/K-718):**
      `20260813000001_add_booking_overlap_guard` adds an EXCLUDE constraint, and Postgres validates it
      against existing rows — so it **refuses to apply** while any two live bookings overlap, and the
      deploy stops there with a constraint error. A fresh box and every `demo:setup` (which rebuilds
      from `db/structure.sql`) are unaffected. Find the offenders BEFORE deploying, with the
      constraint's own predicate:
      ```sql
      SELECT a.id, b.id, a.room_type_id, a.check_in, a.check_out, b.check_in, b.check_out
      FROM bookings a JOIN bookings b
        ON a.room_type_id = b.room_type_id AND a.id < b.id
       AND daterange(a.check_in, a.check_out) && daterange(b.check_in, b.check_out)
      WHERE a.status IN ('reserved','confirmed') AND b.status IN ('reserved','confirmed');
      ```
      Remedy: cancel or delete one of each overlapping pair (they are demo bookings), then re-run the
      migration. Do NOT weaken the constraint — selling one room-night twice is the bug it exists to stop.
- [ ] Enable the systemd unit: `systemctl enable --now kiosk-demo@<app>` (per `deploy/kiosk-demo@.service`, binds 127.0.0.1:<port>).

## 6. Front with Caddy (auto-TLS)
- [ ] **Edge rate-limit module — REQUIRED, do this BEFORE installing the Caddyfile (K-540):**
      `sudo caddy add-package github.com/mholt/caddy-ratelimit` (Caddy ≥ 2.7 swaps in a plugin-included
      binary; `xcaddy build --with github.com/mholt/caddy-ratelimit` is the stable equivalent if you compile
      your own) · `sudo systemctl restart caddy` · confirm with `caddy list-modules | grep rate_limit`.
      A stock Caddy has **no** rate-limiting at all, and at the shipped `WEB_CONCURRENCY=1` a plain flood of
      *any* endpoint saturates the single worker. `POST /kiosk/auth/register` runs the PoW gate
      UNAUTHENTICATED, and PoW prices the attacker's *solve*, never our *verify* — a garbage proof now costs
      0.30 ms instead of 18.7 ms (K-540, cheapest-first + lazy hashing), so it is no longer the cheapest
      lever, but nothing in the app bounds the request RATE. Nothing in the app substitutes for this.
      **Acceptable alternative:** a per-IP rate rule on `/kiosk/*` at a CDN/WAF in front of the box — then
      skip the module and leave the Caddy snippet commented. Deploying with **neither** is the one
      unacceptable option. Detail: `deploy/README.md` §"Edge rate-limit — REQUIRED".
- [ ] Install `deploy/Caddyfile` (**8** vhosts → loopback ports: getgrocery/atablefor/hoteling/skooti/
      stylish/philslist/tudu + `kyc` for the KYC broker). Certs issue automatically.
- [ ] **Uncomment the rate-limit (only after the module is installed):** in `/etc/caddy/Caddyfile` uncomment
      `import ratelimit` inside `(kioskproxy)` AND the whole `(ratelimit)` snippet. They ship **commented**
      because `rate_limit` is not a stock directive — a stock binary refuses the WHOLE config
      ("unrecognized directive: rate_limit", verified on Caddy v2.11.2) and then no site serves at all.
      Then `sudo caddy validate --config /etc/caddy/Caddyfile` · `sudo systemctl reload caddy`.
- [ ] **Prove the edge is limited — do not take the two ticks above on trust (K-976):**
      `/srv/kiosk/deploy/check-edge-ratelimit.sh` · it reads `/etc/caddy/Caddyfile` and names every vhost
      that does not reach a `rate_limit` directive, exit 1 if any does. The uncommenting is a manual step
      and skipping it is otherwise SILENT — the box comes up, all eight sites serve, and nothing anywhere
      says the register endpoint is unbounded. If you took the CDN/WAF route instead, declare it rather
      than skipping the tick: `KIOSK_EDGE_RATELIMIT=external /srv/kiosk/deploy/check-edge-ratelimit.sh`.
- [ ] **HSTS — one `header` line, and it must reach the LIVE Caddyfile too (K-916):** `deploy/Caddyfile`'s
      `(kioskproxy)` snippet emits `Strict-Transport-Security: max-age=31536000; includeSubDomains`, ENABLED
      (unlike the rate-limit above, `header` is a stock directive and needs no module). Without it a client
      typing a bare hostname makes its FIRST request in plaintext, before the `:80`→`:443` redirect — the
      window HSTS exists to close. `config.force_ssl` is deliberately OFF in all eight apps (K-439: Caddy
      already terminates TLS and redirects, and the apps run with `assume_ssl`), so the edge is the ONLY
      place this header can come from. **On the current live box the hand-maintained `/etc/caddy/Caddyfile`
      does not import this snippet** (see the ⚠ below), so add the same `header` line by hand to each demo
      vhost there. Verify: `curl -sI https://getgrocery.demo.kiosk.tech/ | grep -i strict-transport`.
- [ ] Verify the limit bites: hammer `/kiosk/auth/register` from one IP and confirm 429 well before the box slows.
- [ ] ⚠ On the CURRENT live box the `/etc/caddy/Caddyfile` is hand-maintained and also serves other sites —
      do NOT overwrite it with `deploy/Caddyfile` (you would drop the other vhosts). Hand-add the blocks in its
      style instead. See the DRIFT NOTE (K-463) in the Caddyfile header.

## 7. Deploy new code (push-to-deploy) + housekeeping
- [ ] **git push-to-deploy** (mirrors narrathon): a bare repo per box with an ISOLATED `post-receive` hook
      (own work-tree/service names/deploy user — never touches `/opt/narrathon`) that checks out `main`,
      `bundle install`, `db:prepare`, **`db:seed`**, and restarts each app's service.
- [ ] ⚠ **THE HOOK IS NOT IN THIS REPO AND NOTHING BACKS IT UP.** On the live box it is
      `/srv/kiosk.git/hooks/post-receive` — executable, ~1.2 KB, untracked, present in no repository —
      and it is the ONLY thing that turns a push into a deploy. Two consequences to act on:
      (a) **never re-clone or recreate `/srv/kiosk.git`** to realign it with `origin`; that discards the
      hook and leaves a bare repo that accepts pushes and deploys nothing. Realign with
      `git push --force-with-lease=main:<current-remote-sha> prod-demo main` INTO the existing repo.
      (b) **copy the hook off the box before any rebuild** (`scp box:/srv/kiosk.git/hooks/post-receive .`)
      — a rebuild from this checklist alone has to reconstruct it from the prose above.
      What it does, as measured on the box: on any push touching `refs/heads/main` it runs
      `git checkout -f main` into the single work-tree `/srv/kiosk`, then per demo `bundle install`,
      `rails db:migrate`, `rails db:seed` and `systemctl restart kiosk-demo@<app>` across all 8 units,
      then `systemctl reload caddy`.
- [ ] ⚠ **`db:seed` is not optional — omit it and the demos serve empty catalogs.** `db:prepare` seeds only a
      database it has just CREATED, so on every push after the first it is a no-op for content: K-464 records
      live hoteling showing 5 properties instead of 100 and skooti's fleet missing, because the hook ran
      `db:prepare` alone. Seeding on every push is safe — every demo's seeds are idempotent-additive (zero
      `delete_all`, verified live on all seven), so a push tops the catalog up and deletes nothing. This is
      also the only thing that re-seeds the catalog; see `deploy/README.md` step 5.
- [ ] ~~Prune cron~~ — **SKIPPED** (Phil, K-593/K-630) and there is nothing to install: this repo ships no
      scheduled housekeeping at all, and nothing in it reclaims demo accounts — no demo ships a retention
      task. **Reclaiming disk is `deploy/demo-reset.sh`, run by hand**; for what covers the catalog
      re-seed instead, see `deploy/README.md` step 5.

## 8. Verify (per subdomain)
- [ ] `GET https://<app>.demo.kiosk.tech/.well-known/kiosk.json` returns discovery (atablefor shows the "beware" PoW notice).
- [ ] The demo **root page** loads (what it is + a curl one-liner + the live activity counters).
- [ ] `GET https://<app>.demo.kiosk.tech/demo/activity.json` returns aggregates.
- [ ] getgrocery: a Stripe test card `4242 4242 4242 4242` completes a real test-mode pay (the only demo with a payment provider).
- [ ] KYC broker: `GET https://kyc.demo.kiosk.tech/` renders the human explainer (STUB-KYC notice; NO agent/kiosk signal); `GET /prove_key.pem` returns the public key; `GET /.well-known/kiosk.json` is **absent** (404 — it is an issuer, not an operator).

## Notes
- Everything is OFF by default in code — nothing here changes local/CI behavior.
- Test card + Stripe testing docs: https://docs.stripe.com/testing
