# Deploy checklist — hosted demos on kiosk.tech subdomains

Concise, ordered. Detail + file contents: `deploy/README.md`. Operator actions.
Seven demos: getgrocery · atablefor · hoteling · skooti · stylish · philslist · tudu.
Plus the KYC broker (`kiosk-demo-prove` → `kyc.demo.kiosk.tech`, port 3008) —
an ISSUER, not a Kiosk operator (no PoW, no `/.well-known/kiosk.json`, no agent surface).

## 1. DNS (you)
- [ ] Wildcard `*.demo.kiosk.tech` → VPS_IP (one A record; add apps without DNS changes).
      Or per-app A records (`getgrocery.demo.kiosk.tech`, …).

## 2. Provision the VPS (one small box, ~2–4 GB)
- [ ] Install: **Caddy** (stock — there is no rate-limit module to add, see §6), **PostgreSQL**
      (17), **Ruby 4.0.1** via **mise**, git.
- [ ] For comparison, the box this fleet actually runs on, MEASURED over ssh 2026-09-06: an OVH VPS
      with **2 vCPU** (`nproc`) and **3814 MB** RAM (`free -m` total), carrying every deployed app
      plus Postgres plus Caddy. Every throughput number written down in this repository was taken on a
      developer laptop with four times the cores; do not size from them without saying so.
- [ ] **No Python/numpy needed on the server** — it only *verifies* proofs (cheap, pure Ruby). numpy is
      the client's *solver* (`solve.py`); install it on the box ONLY if you want to run the solve-side
      demo smoke tests (`check:shop`/`check:book`/`check:backoff`) there.
- [ ] **Lean Puma** for a small box: `WEB_CONCURRENCY=1` (or 0) + `RAILS_MAX_THREADS=5` per app —
      what every `deploy/env/*.env.example` already ships, so a copied template needs no edit here.
- [ ] **If you raise `WEB_CONCURRENCY` above 1**, the auth-challenge store must be shared across
      workers first — it defaults to in-process, so the auth handshake breaks. See kiosk-server's
      README, "Multi-process deployments". Nothing else on this list changes.
- [ ] `git clone` the reference repo (or push-to-deploy — see §7).

## 3. Databases (one Postgres cluster)
- [ ] `psql -v gg_pw=… -v af_pw=… -v ho_pw=… -v sk_pw=… -v st_pw=… -v pl_pw=… -v td_pw=… -v pv_pw=… -f deploy/postgres-init.sql`  → 8 app DBs + least-priv roles (7 demos + `kiosk_prove`). (Pass each RAW password unquoted — the script escapes it via `:'var'`.)
- [ ] **Only if you renamed something:** the DB/role names default to the shipped ones. If you changed `KIOSK_<APP>_DB` / `KIOSK_<APP>_DB_USER` in an app's env (§4), pass the SAME value here as `-v <xx>_db=` / `-v <xx>_user=` (`gg af ho sk st pl td pv`) — otherwise provisioning creates one name and the app connects to another. See `deploy/README.md` §"Database names".

## 4. Per-app env (`deploy/env/<app>.env.example` DECLARES it; `deploy/rollout.sh` places it)
- [ ] **Put the four secrets nobody here can mint into their own `/etc/kiosk-demo/<unit>.env`, then run the rollout.**
      ```
      ssh <deploy-user>@<box> 'sudo bash -s' < deploy/rollout.sh
      ```
      It writes every unit's env file from the templates — every name, every order, every value this repository
      decides — keeps the `REPLACE_*` values the box already has, mints what nothing off the box holds the other
      half of, backs up what it changes, and **names anything it cannot obtain instead of writing a blank**. The
      four it cannot mint are the DB passwords, the Stripe test key (getgrocery, hoteling, skooti), skooti's unlock key and the broker's
      signing key. It has no flags and is idempotent, so re-running it is also how you answer «is the box what the
      tree declares?» — the question no tick-box can answer. See `deploy/README.md` §"Configuration is DECLARED".
- [ ] Copying a template by hand still works and the boxes below are what it must produce — but then nothing joins
      the box to this tree, which is how both KYC operators served `501` for thirty-five days. Tick the rollout above.

What each unit must carry. For EACH of the 7 apps:
- [ ] `RAILS_ENV=production`, a generated `SECRET_KEY_BASE`, `PGHOST`, `KIOSK_<APP>_DB` / `KIOSK_<APP>_DB_{USER,PASSWORD}`, `PORT` (3001–3007). `KIOSK_<APP>_DB` and `KIOSK_<APP>_DB_USER` default to `kiosk_<app>_production` / `kiosk_<app>` — keep the shipped values and §3 needs no extra flags.
- [ ] **Issuer + signing key (all 7 demos):** `KIOSK_ISSUER` and `KIOSK_SIGNING_KEY_B64` are crash-if-absent
      outside dev/test — the app refuses to boot without them, and so does `zeitwerk:check` in §5. The example ships
      `KIOSK_ISSUER=https://<app>.demo.kiosk.tech`: **change it if you serve a different origin**, because it is the `aud`
      every assistant proof is checked against — a wrong value rejects every assistant with "proof audience mismatch"
      rather than failing loudly at boot.
- [ ] **PoW:** nothing to set — difficulty is fixed in each demo's initializer
      (atablefor n=168 k=7, the other six n=96 k=5).
- [ ] **PoW toll:** atablefor runs the **reputation** anti-scalping policy in production (RateAndReputation with the
      real confirmed-bookings factor) — its initializer's production default, so its env sets nothing for it. At `high`
      a fresh visitor pays ~2 proofs (~20 s) at first contact, dropping to 1 then a free pass as its bookings confirm.
      getgrocery tolls every query and hoteling prices browse depth and holds; both are configured in their
      initializers, with no env flag.
- [ ] ⚠ **UPGRADING AN EXISTING BOX — `deploy/rollout.sh` is the whole of it.** The rollout renders each file from
      its template on every run, so a name no template declares does not come across. It edits only
      `/etc/kiosk-demo/*.env`; it does
      NOT touch Caddy or any throttle (there is deliberately none; see `deploy/README.md` §"Edge rate-limit").
- [ ] **PoW secret (all 7 demos):** set `KIOSK_POW_SECRET=$(openssl rand -hex 32)` — REQUIRED; the app refuses to boot
      without it outside dev/test (a shipped default would be world-readable in the public repo, letting anyone forge a
      trivial-difficulty challenge and turn PoW off). Must be ≥ 32 bytes.
- [ ] **Rental-token signing key (skooti only):** set `KIOSK_UNLOCK_SIGNING_KEY_PEM="$(openssl genpkey -algorithm ed25519)"`
      — REQUIRED, enforced at boot: skooti refuses to start in production without it (and rejects a value that does not
      parse as an Ed25519 **private** key), because the dev keypair it signs with outside production unconditionally ships in this
      public repo — anyone with a clone could mint an unlock token every provisioned lock accepts, past reserve, payment,
      ownership and KYC. Provision/flash the locks with the matching public half
      (`openssl pkey -in key.pem -pubout -outform DER | tail -c 32 | xxd -p -c 32`); any lock still carrying the old
      repo key (`8857880d…`) must be reflashed. The other six operator demos have no locks and need nothing here.
- [ ] **Stripe (getgrocery, hoteling, skooti):** `STRIPE_SECRET_KEY=sk_test_…` (TEST mode — no real charges) in each of their env files; the other demos take no money (no `pay` capability).
- [ ] **Card-setup Checkout render (getgrocery):** `payment_setup`'s `setup_url` is a valid Stripe link, but a relaying agent can truncate its required `#fid…` fragment → **"Something went wrong"** (not the account/deploy — the session is valid; proven agent-side). Mitigated by skill guidance (relay the url verbatim/in full); escalate to an operator-hosted short redirect if it recurs. See `deploy/README.md` §Payments.

### 4b. KYC broker env (copy `deploy/env/kyc-demo.env.example` → `/etc/kiosk-demo/prove.env`)
- [ ] `SECRET_KEY_BASE`, `KIOSK_PROVE_DB` / `KIOSK_PROVE_DB_{USER,PASSWORD}`, `PORT=3008`. No kiosk gem — no signing key / no PoW knob.
- [ ] **Issuer + public URL:** `KIOSK_PROVE_ISSUER=https://kyc.demo.kiosk.tech`, `PROVE_PUBLIC_URL=https://kyc.demo.kiosk.tech`.
- [ ] **Broker signing key:** `PROVE_KEY_PEM=<fresh 2048-bit RSA private PEM>` — REQUIRED, enforced at boot: the
      broker refuses to start in production without it (and rejects a PEM that does not parse as a private key), because
      the baked-in dev key's private half is world-readable in the public repo — silently signing with it would let anyone
      forge attestations, and the pin flows below would faithfully pin its forgeable public half.
- [ ] **Operator allow-list — ONE PAIR PER KYC OPERATOR, and an operator with no pair is silently not registered:**
      `KIOSK_PROVE_SKOOTI_SECRET=<shared intake secret>`, `KIOSK_PROVE_SKOOTI_CALLBACK_HOST=skooti.demo.kiosk.tech`;
      `KIOSK_PROVE_GETGROCERY_SECRET=<a DIFFERENT shared intake secret>`, `KIOSK_PROVE_GETGROCERY_CALLBACK_HOST=getgrocery.demo.kiosk.tech`.
      The KYC operators are the demos whose Gemfile bundles `kiosk-kyc-prove`.
- [ ] **Wire each operator to it:** in THAT operator's env set `KIOSK_PROVE_ISSUER` + `KIOSK_PROVE_BROKER_URL` = `https://kyc.demo.kiosk.tech`, `KIOSK_PROVE_INTAKE_SECRET=<the SAME value as the broker's KIOSK_PROVE_<OP>_SECRET>`, and `KIOSK_PROVE_PUBLIC_KEY_PEM=<public half of PROVE_KEY_PEM>` (or fetch once from `https://kyc.demo.kiosk.tech/prove_key.pem`).
      The names differ by design: every OPERATOR app reads one role-named `KIOSK_PROVE_INTAKE_SECRET`, while
      the BROKER keeps a per-operator name for each registry entry. The two sides pair by VALUE; the broker resolves the
      operator from the `operator_id` in the intake body.
- [ ] **The pair is ONE secret and `deploy/rollout.sh` writes both sides of it.** The operator's
      `KIOSK_PROVE_INTAKE_SECRET` is the source: the broker's `KIOSK_PROVE_<OP>_SECRET` is read from that operator's
      own file, and each operator's `KIOSK_PROVE_PUBLIC_KEY_PEM` is derived from the broker's own `PROVE_KEY_PEM`.
      Setting half of either pair is no longer a thing the rollout can do.
- [ ] **RUN `deploy/kyc-pairing-audit.sh` ON THE BOX — it reads what is deployed, and a tick taken by eye is a guess.**
      ```
      ssh <deploy-user>@<box> 'sudo bash -s' < deploy/kyc-pairing-audit.sh
      ssh <deploy-user>@<box> 'sudo bash -s' -- --fix-retired-names < deploy/kyc-pairing-audit.sh
      ```
      It pairs each operator's `KIOSK_PROVE_INTAKE_SECRET` against the broker's `KIOSK_PROVE_<OP>_SECRET` BY VALUE,
      checks the pinned broker key against the key the broker actually signs with, and names any operator env still
      carrying the RETIRED operator-side spelling. It prints no value: pairing comes out PAIRED or MISMATCH, a key as a
      public SPKI fingerprint. Run it before the restart, and again after.
- [ ] **The RETIRED operator-side name, on any box that predates 2026-08-13.** The operator side was
      `KIOSK_PROVE_<OP>_SECRET` until then and is `KIOSK_PROVE_INTAKE_SECRET` now. Nothing reads the old spelling any
      more, so an env file still carrying it leaves the app with NO secret — and `request_kyc` then answers a cacheable
      `501 module_not_served`, which reads as «this operator does not do KYC» rather than as a missing value. That is not
      hypothetical: it is what BOTH deployed KYC operators did from 2026-08-13 to 2026-09-17, with a correct secret
      stored under the dead name on each box, until a live third-party assistant reported the alcohol in its getgrocery
      basket as unbuyable by any route. The audit above is the box-side control.
      **What a missed pair looks like from outside, so it is not mistaken for a design choice:** the origin still
      ADVERTISES `request_kyc` in `/kiosk/schema` — the descriptor is static — and answers the verb
      `501 module_not_served`. No unauthenticated probe can tell that apart from an operator that genuinely serves no
      KYC module.

## 5. Build + boot each app
- [ ] **Eager-load gate FIRST, on every changed app:**
      ```
      RAILS_ENV=production SECRET_KEY_BASE=throwaway \
        KIOSK_POW_SECRET=throwaway-at-least-32-bytes-long-xxxx \
        KIOSK_ISSUER=https://throwaway.example.test \
        bin/rails zeitwerk:check                     # getgrocery, hoteling, skooti: add STRIPE_SECRET_KEY=sk_test_throwaway
                                                     # prove: add PROVE_KEY_PEM="$(openssl genrsa 2048)" — it must PARSE
                                                     #   as an RSA private key — a throwaway literal will not do;
                                                     #   the kiosk vars above are ignored by the broker (harmless)
                                                     # skooti: add KIOSK_UNLOCK_SIGNING_KEY_PEM="$(openssl genpkey \
                                                     #   -algorithm ed25519)" — same rule, it must PARSE as an Ed25519
                                                     #   PRIVATE key
      ```
      It eager-loads the whole app the way production does and exits non-zero on the first constant/path mismatch — the
      class that 502s an app on boot, invisible to every dev-mode gate. Needs no database (it loads
      code, it does not connect). Every value here is a throwaway: nothing is signed, served or dialed.
      The three env vars are not optional decoration — each is crash-if-absent in `production`, and a missing one aborts
      in the initializer BEFORE Zeitwerk runs, so the command exits 1 for a reason that has nothing to do with eager
      loading (`KIOSK_POW_SECRET`, `KIOSK_ISSUER`, the paying demos' Stripe key/mock URL, the broker's
      `PROVE_KEY_PEM`, skooti's `KIOSK_UNLOCK_SIGNING_KEY_PEM`). Verified on all 8 apps.
      CI runs the same gate for all 8 apps on every push, so a green CI on the exact commit you are deploying is the same
      gate; run it by hand whenever you deploy a tree CI has not seen. **If an initializer ever learns to raise outside
      dev/test, add the variable HERE and in `.github/workflows/ci.yml` in the same commit** — these two are one gate
      written twice, and this copy is the one a human types.
- [ ] `bundle install` · `RAILS_ENV=production bin/rails assets:precompile db:prepare` · `bin/rails db:reset` (seed).
- [ ] Enable the systemd unit: `systemctl enable --now kiosk-demo@<app>` (per `deploy/kiosk-demo@.service`, binds 127.0.0.1:<port>).

## 6. Front with Caddy (auto-TLS)
- [ ] **Deploy the Caddyfile with `deploy/deploy-caddy.sh`, from a workstation that can ssh to the
      box — NOT by hand on the box.** `deploy/deploy-caddy.sh` alone stages the file, has the BOX's
      own caddy validate it and prints the diff, changing nothing; `--apply` backs up
      `/etc/caddy/Caddyfile`, installs, reloads, verifies the LIVE WIRE and rolls back if the wire
      disagrees. It ships the whole file or nothing — no patched lines, no merge — so `deploy/Caddyfile`
      is the source of truth and a hand-edit on the box is something the next `--apply` silently
      reverts.
      <!-- count: 8 ¦ from: grep -cE '^[a-z0-9.-]+\.demo\.kiosk\.tech \{' deploy/Caddyfile -->
      **8** vhosts → loopback ports (getgrocery/atablefor/hoteling/skooti/stylish/philslist/
      tudu + `kyc` for the KYC broker); certs issue automatically on first request.
- [ ] **There is NO edge rate-limit module to install, and no snippet to uncomment.** The per-IP
      throttle is deliberately not a default: a Kiosk proof verifies in milliseconds, so a flood of
      junk proofs costs the sender more than the origin.
      `deploy/Caddyfile` ships `import ratelimit` and the whole `(ratelimit)` snippet
      COMMENTED, that file is what the box runs, and `--apply`'s wire check bursts an origin 75 times
      and fails if a 429 comes back. Do not tick this as a skipped step — there is no step.
      The exposure the snippet covers has not gone away and the analysis is kept beside the commented
      block in `deploy/Caddyfile` and in `deploy/README.md` §"Edge rate-limit"; if the box ever
      actually falls over, re-enable it IN THE REPO and deploy, then pick the bound from a burst
      rather than from either number written down (1 req/s live, 60/min in the snippet, neither
      derived from a measurement).
- [ ] **HSTS arrives because the Caddyfile carries it, not because you pasted it.**
      `deploy/Caddyfile`'s `(kioskproxy)` snippet emits
      `Strict-Transport-Security: max-age=31536000; includeSubDomains`, ENABLED — `header` is a stock
      directive and needs no module — and every vhost imports that snippet. Without it a client typing
      a bare hostname makes its FIRST request in plaintext, before the `:80`→`:443` redirect, which is
      the window HSTS exists to close. `config.force_ssl` is deliberately OFF in every app behind the
      proxy (Caddy already terminates TLS and redirects, and the apps run with `assume_ssl`), so
      the edge is the ONLY place this header can come from.
- [ ] **Prove HSTS actually arrives — do not take the tick above on trust:**
      `deploy/check-live-hsts.sh` · it probes every vhost `deploy/Caddyfile` declares and names each
      origin that does not answer `max-age >= 31536000; includeSubDomains`, exit 1 if any does not.
      A checklist line is not a mechanism: tick this one by running the probe, never by reading the
      template — a template can carry the header while the box serves without it.
- [ ] **Prove the throttle is really off, and burst before you probe the sibling:** the
      snippet's bucket is per-IP across every vhost, so 60+ sequential requests to one origin would
      429 the other seven — and it drains in under a minute, so a sibling probed AFTER the burst
      answers 200 whether or not a limiter exists. Probe the sibling while the burst is still
      running, or an absent limiter and a drained window read identically. `deploy-caddy.sh --apply`
      does exactly that, inside its verify step.
## 7. Deploy new code (push-to-deploy) + housekeeping
- [ ] **git push-to-deploy**: a bare repo per box with its own `post-receive` hook — its own work-tree,
      service names and deploy user, so it touches nothing else the box happens to host — that checks
      out `main`, `bundle install`, `db:migrate`, **`db:seed`**, and restarts each app's service.
- [ ] ⚠ **THE HOOK IS `deploy/post-receive` IN THIS REPO, AND INSTALLING IT IS MANUAL.** On the live box it is
      `/srv/kiosk.git/hooks/post-receive` — executable, outside any clone — and it is the ONLY thing that turns
      a push into a deploy. Two consequences to act on:
      (a) **never re-clone or recreate `/srv/kiosk.git`** to realign it with `origin`; that discards the
      hook and leaves a bare repo that accepts pushes and deploys nothing. Realign with
      `git push --force-with-lease=main:<current-remote-sha> prod-demo main` INTO the existing repo.
      (b) **on a new or rebuilt box, AND after every change to `deploy/post-receive`, install it** — a push does
      not update the hook it runs:
      ```
      scp deploy/post-receive <deploy-user>@<box>:/srv/kiosk.git/hooks/post-receive
      ssh <deploy-user>@<box> chmod +x /srv/kiosk.git/hooks/post-receive
      ```
      If the live hook is edited on the box, copy it back into `deploy/post-receive`.
      What it does: on any push touching `refs/heads/main` it runs
      `git checkout -f main` into the single work-tree `/srv/kiosk`, then per demo `bundle install`,
      `rails db:migrate`, `rails db:seed` and `systemctl restart kiosk-demo@<app>` across all 8 units,
      then `systemctl reload caddy`. **A failed `db:migrate` stops that unit**: it is not seeded or restarted, so it
      keeps serving its previous process, while `/srv/kiosk` already holds the new `main`; the push prints
      `DEPLOY FAILED for: <units>` and exits non-zero (the commits have landed regardless). Fix the cause, then
      re-push or run `db:migrate` and `systemctl restart kiosk-demo@<app>` for those units by hand.
- [ ] ⚠ **A NEW ENV KEY GOES ON THE BOX BEFORE THE PUSH.** When a push makes an app require a name its
      `/etc/kiosk-demo/<unit>.env` lacks, place it and run `deploy/rollout.sh` FIRST, then push `prod-demo` — the
      app cannot boot without it, so neither can its `db:migrate`.
- [ ] ⚠ **`db:seed` is not optional — omit it and the demos serve empty catalogs.** `db:prepare` seeds only a
      database it has just CREATED, so on every push after the first it is a no-op for content: a box whose hook
      runs `db:prepare` alone serves a partial catalog — hoteling with 5 properties instead of 100, skooti with
      no fleet. Seeding on every push is safe — every demo's seeds are idempotent-additive (zero
      `delete_all`, verified live on all seven), so a push tops the catalog up and deletes nothing. This is
      also the only thing that re-seeds the catalog; see `deploy/README.md` step 5.
- [ ] ⚠ **A SCHEMA THAT HAS DIVERGED IS REBUILT BY `deploy/demo-reset.sh`. `db:migrate` CANNOT DO IT.**
      A long-lived box runs a migration exactly once and never again, so anything that reaches
      `db/schema.rb` by a route other than a NEW migration file — an edit to a migration the box has
      already recorded, a renumbering — lands on every from-zero database and on no running one. The
      renumbering case is worse than silent: `db:migrate` aborts at the first re-created object with
      `PG::DuplicateTable`, so the steps after it never run and the exit is buried in hook output. Symptom
      is a 500 on a page whose SELECT names the missing column. The rebuild:
      ```
      ssh <deploy-user>@<box> 'bash /srv/kiosk/deploy/demo-reset.sh'   # AFTER deploying head
      ```
      It `db:schema:load db:seed`s the six non-getgrocery demos and re-seeds getgrocery ADDITIVELY, so the
      real third-party orders it holds survive (pass `--all` only if you mean to destroy them). Verify with
      `deploy/production-smoke.sh` plus a plain `curl -sI https://<app>.demo.kiosk.tech/` → 200, and name any
      missing object from the box (`\d users`) rather than inferring it.
- [ ] ~~Prune cron~~ — **SKIPPED**, and there is nothing to install: this repo ships no
      scheduled housekeeping at all, and nothing in it reclaims demo accounts — no demo ships a retention
      task. **Reclaiming disk is `deploy/demo-reset.sh`, run by hand**; for what covers the catalog
      re-seed instead, see `deploy/README.md` step 5.

## 7b. Rebuild every database on a collapsed migration set (one-time, after a squash)
When a tree collapses the demos' `db/migrate/` into a fresh install, no deployed database has any of
the new versions recorded, so the hook's `db:migrate` would re-create tables that exist and stop. Each
database is dropped and rebuilt from `db/schema.rb` instead. **All fleet data is lost**: orders,
bookings, KYC grants and verifications, bound assistants and every account the seeds do not create —
getgrocery's real third-party orders included.
- [ ] Install the current hook (the push below runs it):
      ```
      scp reference/deploy/post-receive <deploy-user>@<box>:/srv/kiosk.git/hooks/post-receive
      ssh <deploy-user>@<box> chmod +x /srv/kiosk.git/hooks/post-receive
      ```
- [ ] Stop every unit and recreate its database empty, same name and owner (names from each unit's own
      env file, as `deploy/demo-reset.sh` reads them):
      ```
      ssh <deploy-user>@<box> 'bash -s' <<'SH'
      for a in getgrocery atablefor hoteling skooti stylish philslist tudu prove; do
        A=$(printf %s "$a" | tr '[:lower:]' '[:upper:]')
        names=$(set -a; . /etc/kiosk-demo/$a.env; set +a; dv=KIOSK_${A}_DB; uv=KIOSK_${A}_DB_USER
                printf '%s %s' "${!dv:-kiosk_${a}_production}" "${!uv:-kiosk_${a}}")
        db=${names% *}; role=${names#* }
        sudo systemctl stop "kiosk-demo@$a"
        sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<SQL
      DROP DATABASE IF EXISTS "$db" WITH (FORCE);
      CREATE DATABASE "$db" OWNER "$role";
      REVOKE CONNECT ON DATABASE "$db" FROM PUBLIC;
      GRANT CONNECT ON DATABASE "$db" TO "$role";
      SQL
      done
      SH
      ```
- [ ] Push: `git -C reference push prod-demo main`. On an empty database the hook's `db:migrate` loads
      `db/schema.rb` (which records every migration), then `db:seed` and `systemctl restart` run as on
      any deploy. The push must end `deploy complete.`
- [ ] By hand instead of the push, per app on the box, as the hook does:
      ```
      export PATH=$HOME/.local/share/mise/installs/ruby/4.0.1/bin:$PATH
      cd /srv/kiosk/kiosk-demo-<app>
      (set -a; . /etc/kiosk-demo/<app>.env; set +a; bundle exec rails db:migrate && bundle exec rails db:seed)
      sudo systemctl start kiosk-demo@<app>
      ```
- [ ] Verify as §8; `\d` on any table in `psql` shows the shape `db/schema.rb` states.

## 8. Verify (per subdomain)
- [ ] `GET https://<app>.demo.kiosk.tech/.well-known/kiosk.json` returns discovery (atablefor shows the "beware" PoW notice).
- [ ] The demo **root page** loads (what it is + the live activity counters). The copy-paste curl
      flow lives in `deploy/README.md` §"Poke it"; no landing page carries one.
- [ ] getgrocery, hoteling, skooti: a Stripe test card `4242 4242 4242 4242` completes a real test-mode pay.
- [ ] KYC broker: `GET https://kyc.demo.kiosk.tech/` renders the human explainer (STUB-KYC notice; NO agent/kiosk signal); `GET /prove_key.pem` returns the public key; `GET /.well-known/kiosk.json` is **absent** (404 — it is an issuer, not an operator).
- [ ] **KYC pairing — `deploy/kyc-pairing-audit.sh` exits 0 on the box.** Nothing probed from outside can stand in for
      it: `request_kyc` is reach `principal`, so an unauthenticated call answers 401 whatever the module is doing, and a
      misconfigured operator answers the authenticated call a cacheable `501 module_not_served` indistinguishable from an
      operator that serves no KYC at all. A green descriptor is not evidence — the verb list is static.

## Notes
- Everything is OFF by default in code — nothing here changes local/CI behavior.
- Test card + Stripe testing docs: https://docs.stripe.com/testing
