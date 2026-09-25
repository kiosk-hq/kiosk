# Kiosk hosted live demos — deploy runbook

Runbook for hosting the 7 Kiosk demo Rails apps **plus the KYC broker**
— 8 apps <!-- count: 8 ¦ from: git ls-files 'deploy/env/*.env.example' | wc -l --> — on **one small VPS**, one **Postgres** cluster (DB-per-app), fronted
by **Caddy** (auto-TLS), each app a loopback **Puma** under **systemd** — sized
to survive an HN stampede.

This directory is the *app-side* handoff; DNS + VPS provisioning is the operator's.

## Files in this directory

| File | What it is |
|------|-----------|
| `Caddyfile` | One vhost per app subdomain (8) → loopback Puma; automatic TLS. Emits **HSTS** (stock `header` directive, enabled). Carries the per-IP edge rate-limit **commented out and deliberately so** — there is no default throttle (see below). This file is the source of truth for `/etc/caddy/Caddyfile`; do not hand-edit the box. |
| `postgres-init.sql` | 8 databases + 8 least-privilege login roles (DB-per-app; 7 demos + the KYC broker). Names default to the shipped ones and are overridable — see [Database names](#database-names). |
| `kiosk-demo@.service` | Parameterised systemd unit: one Puma per app (`%i`). |
| `env/<app>.env.example` | Per-app env template (7 demos + `kyc-demo.env.example` for the broker). Copy to `/etc/kiosk-demo/<app>.env`. |
| `rollout.sh` | **The only supported way `/etc/kiosk-demo/*.env` is set.** Run it ON THE BOX. It renders every unit's env file from `env/<app>.env.example` — names, order, comments and every value this repository decides — and fills the `REPLACE_*` slots from the box's own current values or from an operator-supplied vault file. `--check` answers «is the live configuration what this tree says it should be?» and changes nothing; `--apply` brings a drifted box into line, backs up what it changes, names the units to restart and restarts none of them. It carries no secret and prints none, and it changes no file's owner, group or mode — it reports them instead. On a box with nothing to source from it NAMES what is missing and writes nothing, rather than writing a blank. `--self-test` builds a throwaway tree and proves the parser, idempotence, drift correction, the refusal, and both directions of the KYC pairing; it touches no host and runs in CI. |
| `box-prep-2026-08-11.sh` | **Spent — a record of what was done on that date, not a step.** It stripped the legacy PoW flags and the long-dead `KIOSK_POW_REGISTER_DEMO` from the hand-maintained env files, one time, before the deploy that followed. Everything it did is now a standing property of `rollout.sh`, which removes a retired name on every `--apply` instead of once. Kept, because a dated one-shot is history; do not run it. |
| `deploy-caddy.sh` | **The only supported way `Caddyfile` reaches the box.** `--check` stages the file, has the BOX's own caddy validate it, and prints the diff, changing nothing; `--apply` backs up, installs, reloads, then verifies the LIVE WIRE and rolls back if the wire disagrees. It ships the whole file or nothing — never a patched line, never a merge — so a divergence in either direction shows up as a diff. `--self-test` exercises the derivation and the two posture arms (HSTS declared, limiter NOT enabled) and touches no host; it runs in CI. |
| `check-live-hsts.sh` | **Run it from anywhere to audit the fleet, and after any Caddyfile change.** Probes each vhost in `Caddyfile` over HTTPS and names every origin that does not answer `Strict-Transport-Security` with `max-age >= 31536000; includeSubDomains`. It reads the WIRE rather than a config, because a config check on the template says OK for as long as the box serves without the header. `--self-test` proves the judging both ways plus two vacuity arms, and runs in CI; the live probe does not, because CI must not depend on a box this repo does not deploy. |
| `live-fleet-drive.rb` | **Run it by hand after a deploy — it is not a CI job.** Drives every vhost in `Caddyfile` with the drivers this repo ships (`Kiosk::Redteam::Wire`, `Kiosk::Redteam::Client`) and then runs `e2e/schema_conformance.rb` against the bytes each origin served — the only place §16.3's «every wire object validates against its JSON Schema» is asserted about a DEPLOYED byte rather than a localhost one. **Every probe is read-only**: the two registration probes are the ones that must be REFUSED, and the query probes carry a forged bearer or none, so no domain row is created and none is deleted. The one residue is measured and named in the script's header — the possession handshake's `GET /auth/challenge` leaves a single-use nonce per origin in that origin's in-process TTL store, which expires unaided and reaches no database. It therefore cannot run the shipped `Scenarios::*` battery, each of which registers principals and stages state — including `RegistrationWithoutPow`, whose control registers successfully. It borrows a demo's bundle automatically (`KIOSK_DRIVE_BUNDLE` picks another). `--self-test` covers the vhost derivation and the TLS seam and touches no host; the live drive stays out of CI for `check-live-hsts.sh`'s reason — CI must not depend on a box this repo does not deploy. |
| `demo-reset.sh` | Run ON THE BOX to put demo data back to a clean, freshly-seeded state: drops + reseeds the six non-getgrocery demos, additively reseeds getgrocery (its orders are real third-party assistant runs and seeding cannot reproduce one); `--all` wipes getgrocery too. This is the disk-reclaim tool. |
| `production-smoke.sh` | **Not a deployment tool — do not run it on a deploy host.** A `RAILS_ENV=production` boot smoke for one demo per unique HTML surface plus the one whose HTML is rendered from a hand-written SQL projection (`stylish` \| `prove` \| `tudu`), catching the eager-load / proxy-CSRF / assistant-shaped-error classes that dev-mode CI cannot see. CI is its caller. It CREATES AND DROPS `kiosk_<app>_smoke`, so `require_disposable_host()` aborts outright when the box carries deploy markers (`/srv/kiosk`, `/etc/kiosk-demo`, an installed `kiosk-demo@.service`) and otherwise demands `CI` or `KIOSK_SMOKE_I_AM_DISPOSABLE=1`. |
| `kyc-pairing-audit.sh` | **Run it ON THE BOX after any KYC-related env change, and on any box that predates 2026-08-13.** Reads `/etc/kiosk-demo/*.env` and reports whether each KYC operator's intake secret actually pairs with the broker's registry entry, whether the pinned broker public key is the one the broker signs with, and whether an operator env still carries the retired `KIOSK_PROVE_<OP>_SECRET` spelling; `--fix-retired-names` renames it in place, after a backup. **It prints no value** — pairing comes out as PAIRED/MISMATCH and a key as a public SPKI fingerprint. It exists because `bin/check-kyc-operator-pairing` holds the shipped templates and says in its own header that it cannot see the values on the boxes: both operators answered `501 module_not_served` for thirty-five days with correct secrets stored under a name the app had stopped reading. |
| `CHECKLIST.md` | The tick-through version of this runbook — what an operator actually ticks off on deploy day, incl. the recorded skips. |
| `README.md` | This runbook. |

## Configuration is DECLARED, and a wipe is a question with an answer

`/etc/kiosk-demo/<app>.env` is what every unit reads, and an env file a hand
maintains is joined to this repository by nothing. The cost of that is not
theoretical: an app whose secret sits under a name it does not read fails CLOSED
and SILENTLY — the descriptor still advertises the verb, the verb answers a
cacheable `501 module_not_served`, and no request from outside can tell that
apart from an operator that genuinely serves no such module. Both KYC operators
answered exactly that for thirty-five days. A rename that ships with a sentence
asking deploys to follow it has shipped no mechanism at all.

`rollout.sh` is the mechanism. **`deploy/env/<app>.env.example` is the
declaration** — the variable set, the order, the comments and every value this
repository gets to decide — and the script renders it onto the box, filling only
the `REPLACE_*` slots. So there is exactly one place to change the fleet's
configuration, and it is a file in this repository:

```sh
ssh <deploy-user>@<box> 'sudo bash -s' -- --check < deploy/rollout.sh   # is the box what the tree says?
ssh <deploy-user>@<box> 'sudo bash -s' -- --apply < deploy/rollout.sh   # make it so
```

The declaration it reads is the checkout **on the box** (`/srv/kiosk`), not
`main` — an env file belongs to the code that reads it, and that is the code the
units are running. So a box behind `main` is checked against templates that are
behind it too; deploy first if the question you mean is «does the fleet match
head».

`--check` changes nothing and exits 1 when a declared variable is missing,
empty, still a placeholder or carrying a value the tree disagrees with, when a
retired name is still assigned, or when the two sides of the shared KYC secret
do not pair. Ordering and comments are reported and are never red — one
`--apply` settles them — so the first run against a hand-maintained fleet
answers the question that matters instead of a cosmetic one.

**Where secrets come from, and what happens on a wiped box.** The script
contains no secret and prints none. Each value is taken from the vault file if
there is one (`/etc/kiosk-demo/secrets.env`, or `--secrets`, holding
`<UNIT>__<VARIABLE>=…` lines) and otherwise from the value already on the box —
so a re-run on a healthy fleet rotates nothing. On a box where neither source
has it, the script **names that variable and writes nothing at all**: a blank
secret is worse than a refusal, because an app that boots with one fails closed
and silently, which is precisely the failure this script exists to end.

`--apply --generate-missing` then mints the values nothing off this box can hold
the other half of — the session key, the proof-of-work secret, the operator
signing key, and the shared KYC intake secret whose two sides both live here —
and prints their names. It still refuses, by name and with the command that
produces each, the four whose other half is somewhere else: the database
passwords (Postgres has them, from `postgres-init.sql`), getgrocery's Stripe
test key, skooti's unlock signing key (its public half is flashed into the
locks) and the KYC broker's own signing key (a new one invalidates every
attestation already issued). **So a rebuilt box needs those four values from
whoever holds them, and nothing else.**

**The KYC pair is handled as one secret.** The operator reads
`KIOSK_PROVE_INTAKE_SECRET` and the broker reads `KIOSK_PROVE_<OP>_SECRET` — two
names for one value, by design — so the vault names it once, as
`KYC_INTAKE_SECRET_<OP>`, and the script writes both sides from it. A vault key
that could set one side alone is refused, and so is a box where both sides are
set and disagree: choosing between two live secrets is not a configuration
run's to make.

**What it does not touch.** Caddy (that is `deploy-caddy.sh`, which owns
`/etc/caddy/Caddyfile` whole), Postgres, migrations, seeds, the units
themselves — it prints the `systemctl restart` line for each unit whose file it
changed and runs none of them — and the owner, group and mode of any env file.

**Who reads an env file is not something this repository knows.** The unit gets
it through `EnvironmentFile=` and runs as `kiosk`; the push-to-deploy hook at
`/srv/kiosk.git/hooks/post-receive` **also sources every one of them**, as
whatever account a push arrives as, and nothing on disk records what that
account is. So `rollout.sh` does not set those attributes at all — an existing
file keeps exactly what it has, and a new one inherits from a sibling or from
the directory — and instead every run REPORTS, per file, the owner, the group,
the mode, and whether the hook's account can read it. That report is never red,
in any mode: the script did not choose those attributes and cannot repair them,
so a red exit would be a gate over somebody else's decision.

The account it compares against is the one thing it cannot measure. Give it with
`--hook-account <user>` when you know it; otherwise it uses the owner of the hook
file and says in as many words that this is an INFERENCE, and when the hook is
not there it reports the account as undetermined rather than reporting agreement.

### Give the env files their permissions back

If a run of anything has left `/etc/kiosk-demo/*.env` unreadable to the account
the deploy hook runs as, the symptom is silent: every unit's `db:migrate` fails
with `Permission denied` on the hook's own `source`, and the push still prints
`deploy complete`. The units keep serving, because they read the file as
`kiosk` through systemd — so nothing looks wrong until a deploy carries a
migration that never ran.

**The repair derives the right attributes from the box, because we do not know
what they were.** `rollout.sh` backs a file up with `cp -p` before it writes it,
once per day per file and never overwriting, so the OLDEST `<unit>.env.bak-*`
beside each file carries the owner, group and mode that file had before anything
touched it. Look first, then copy them across:

```sh
# LOOK FIRST. Nothing below is safe to run without reading this.
ssh <deploy-user>@<box> '
  ls -ld /etc/kiosk-demo /srv/kiosk.git/hooks/post-receive
  ls -l  /etc/kiosk-demo
  id
  sudo cat /srv/kiosk.git/hooks/post-receive
'

# RESTORE each env file from its own oldest backup. GNU chown/chmod copy the
# attributes off a reference file, so no owner and no mode is typed in here.
ssh <deploy-user>@<box> 'sudo sh -c "
  cd /etc/kiosk-demo || exit 1
  for f in *.env; do
    b=
    for c in \$f.bak-*; do [ -e \"\$c\" ] && { b=\$c; break; }; done
    [ -n \"\$b\" ] || { echo \"no backup beside \$f — nothing to derive from\"; continue; }
    chown --reference=\"\$b\" \"\$f\" && chmod --reference=\"\$b\" \"\$f\" && echo \"\$f <- \$b\"
  done
  ls -l
"'

# CONFIRM, from the box's own account rather than from this page.
ssh <deploy-user>@<box> 'sudo bash -s' -- --check --hook-account <deploy-user> < deploy/rollout.sh
```

If a file has no backup beside it — a box rebuilt since, or a file this fleet
never wrote — there is nothing to derive from and the answer is a decision
rather than a command: state the triple yourself, on the DIRECTORY, and re-run
`--apply`, which gives every file it creates the directory's own posture.

## Per-demo map

| Demo | Subdomain | Port | PoW difficulty | Stripe (test) |
|------|-----------|------|----------------|---------------|
| getgrocery | `getgrocery.demo.kiosk.tech` | 3001 | **low** (sub-second, poke-friendly) | yes |
| atablefor  | `atablefor.demo.kiosk.tech` | 3002 | **HIGH** (~9–10 s on an M-series laptop core, "beware: intensive PoW") | — (no payment provider) |
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
a low/fast toll so a poker can register in well under a second and still SEE
the toll; only
**atablefor** — the designated production-grade showcase — ships the high
memory+CPU-hard toll behind a "beware: intensive PoW" banner so the toll is
tangible first-hand. (The toll prices abuse; it is not by itself a DoS shield,
and there is deliberately no default edge throttle — see "Edge rate-limit"
below.) Any other demo is knob-adjustable: set
`KIOSK_POW_DIFFICULTY=high` on it too to feel its own toll.

> **How it wires (WIRED).** All seven demos'
> <!-- count: 7 ¦ from: git grep -l 'Kiosk::Pow::Equihash::Difficulty' -- 'kiosk-demo-*/config/initializers/kiosk.rb' | wc -l -->
> initializers read
> `ENV["KIOSK_POW_DIFFICULTY"]` (`low` default, `high` opt-in) via
> `Kiosk::Pow::Equihash::Difficulty` and set their Equihash params accordingly:
> - **low** → `{n:96,k:5}` — sub-second reference solve, poke-friendly.
> - **high** → `{n:168,k:7}` — the shipped Equihash default: ~1.3 GiB and ~10 s
>   per proof on the reference (numpy) solver, the seconds measured on one
>   M-series laptop core and on no other hardware (the ~1.3 GiB is THAT
>   solver's sorted-nonce table, not a floor `(n=168, k=7)` imposes on every
>   implementation — a memory-optimised solver trades the table for time,
>   which is how Equihash 200/9's real footprint fell to ~144 MB) — a real
>   memory+CPU toll. Verified to clear (measured 8.9–9.5 s on that same
>   machine) end-to-end.
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
   take their share). Install Postgres 17, a **stock** Caddy (no module: there
   is no default edge throttle — see "Edge rate-limit" below), Ruby, and a
   non-login `kiosk` service user. **No toolchain pin ships**: `mise.toml`,
   `.mise.toml` and `.ruby-version` are gitignored repository-wide, so a clone
   carries none and the interpreter is yours to pick. What the apps are built
   and gated on is the version `.github/workflows/ci.yml` names at its
   `setup-ruby` steps — `4.0.1` today, typed in the workflow.

   **What the box we actually run IS, measured over ssh 2026-09-06 and written
   down because until now nothing anywhere recorded it:** an **OVH** VPS (the
   host itself is `deploy-caddy.sh`'s default), **2 vCPU** (`nproc` → 2;
   `/proc/cpuinfo` model name "Intel Core Processor (Haswell, no TSX)") and
   **3814 MB** of RAM (`free -m` total), i.e. the low end of the range above,
   running every deployed app plus Postgres plus Caddy. Every throughput figure
   in this repository — 4.46 ms to verify a proof, 60 registrations/s, 1075
   reads/s on one worker — was taken on a developer laptop, NOT here, and this
   box has a quarter of that laptop's cores. Any sizing argument that has been made from those numbers was
   guessing at this line; scale them before reusing them, or better, measure on
   the box.

   **What the EDGE on that box is, measured over ssh 2026-09-15, read-only:**
   the Caddy binary is stock — `caddy list-modules` names no rate-limit module —
   and `/etc/caddy/Caddyfile` carries no live `rate_limit` directive, every
   mention of it in the file being a comment. `caddy validate` answers *Valid
   configuration*, the service is active, `caddy version` is **v2.11.4**. So
   there is no per-IP throttle on the box, which is the posture
   "Edge rate-limit" below describes.

   **Nothing pins the package, and a Caddy upgrade is a thing somebody runs.**
   `apt-mark showhold` on that box answers nothing. `unattended-upgrades` is
   enabled and active there, but it will never touch Caddy — its
   `Unattended-Upgrade::Allowed-Origins` lists only the distribution, its
   `-security` pocket and the two ESM security pockets, while `apt-cache policy
   caddy` shows the package coming from
   `https://dl.cloudsmith.io/public/caddy/stable/deb/debian`. So a Caddy
   security release lands only when a human takes it, on the box
   `deploy-caddy.sh`'s `KIOSK_CADDY_HOST` names:

   ```
   apt list --upgradable 2>/dev/null | grep -i caddy  # is an upgrade pending?
   sudo apt install --only-upgrade caddy              # with a human watching
   ```

   It restarts the proxy in front of every origin, so afterwards confirm `caddy
   version`, `systemctl is-active caddy`, `caddy validate --config
   /etc/caddy/Caddyfile --adapter caddyfile` and a request to each vhost. Do not
   hold the package, and do not add the rate-limit module back: there is no
   default throttle here on purpose.
3. **Set real secrets — and then let `rollout.sh` place them.** The values are
   yours: a secret key base and a signing key per app, the DB passwords you
   passed to `postgres-init.sql`, a PoW secret, a Stripe **test** key for
   getgrocery, skooti's unlock key, the KYC broker's signing key. Put them in
   `/etc/kiosk-demo/secrets.env` (mode `0600`) as `<UNIT>__<VARIABLE>=…` and run
   `deploy/rollout.sh --apply`; it writes every env file from
   `env/<app>.env.example` and names anything it could not obtain instead of
   writing a blank. It edits CONTENT only: a file that already exists keeps its
   owner, its group and its mode untouched, and a file it creates inherits them
   from a sibling env file or from `/etc/kiosk-demo` itself — so decide those on
   the directory, once, and every file follows. Copying a template by hand still
   works and the templates are shell-source-safe as written (`set -a; . file`),
   but then nothing joins the box to the tree — see "Configuration is DECLARED"
   above.
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

<!-- fence-count: 8 DBs ¦ from: git ls-files 'deploy/env/*.env.example' | wc -l -->
<!-- fence-count: 7 demos ¦ from: git ls-files 'kiosk-demo-*/config/initializers/kiosk.rb' | wc -l -->
<!-- fence-count: ON_ERROR_STOP=1 ¦ why: a psql flag value, not a quantity -->
<!-- fence-count: max_connections=100 ¦ why: a Postgres setting this runbook asks you to type, not a count of anything here -->
<!-- fence-count: step #3 ¦ why: a pointer to a numbered step above, not a quantity -->
<!-- fence-count: answer 429 ¦ why: an HTTP status code -->
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


# 4. Caddy: deploy this directory's Caddyfile, declaratively. Run it from a
#    workstation that can ssh to the box, NOT on the box -- it is the thing
#    that talks to the box. Caddy fetches a cert per subdomain on first request
#    (HTTP-01). For a single wildcard cert instead, see the DNS-01 note in the
#    Caddyfile header.

#    There is NO module to install and no snippet to uncomment: the per-IP edge
#    throttle is deliberately NOT a default (see "Edge rate-limit" below). Do
#    not hand-edit /etc/caddy/Caddyfile either -- deploy/Caddyfile is the
#    source of truth and --apply overwrites the whole file.
deploy/deploy-caddy.sh            # CHECK: remote validate + diff, changes nothing
deploy/deploy-caddy.sh --apply    # install, reload, verify the wire, roll back on failure
#    --apply verifies the LIVE RESPONSE rather than the installed file: every
#    vhost it derives from the Caddyfile must answer, must send HSTS, and must
#    NOT answer 429 during a 75-request burst. If any of that disagrees it
#    restores the backup it took and reloads, so a bad config does not stick.

# 5. Housekeeping: NOTHING TO INSTALL. There is no cron and no timer here, and
#    nothing in this repo reclaims demo ACCOUNTS — on a schedule or otherwise.
#    No demo ships a retention task. The two jobs a nightly cron would have done
#    are each already covered by something you run or already ran:
#
#      * RE-SEEDING the shared catalog — the push-to-deploy hook does it, running
#        `db:seed` on every push. Every demo's seeds are idempotent and
#        additive (zero delete_all, verified live on all seven), so a push tops
#        the catalog up and deletes nothing.
#
#      * RECLAIMING DISK — deploy/demo-reset.sh, by hand on the box, when a demo
#        DB has grown from poking. On demand rather than nightly because the
#        demos are per-agent isolated: a poker's junk is invisible to the next
#        poker, so disk is the only cost it imposes.
```


## Edge rate-limit -- NOT a default, and that is a decision

**There is no per-IP throttle on this fleet.** A Kiosk proof verifies in
milliseconds, so a flood of junk proofs costs the sender far more than it costs
the origin; the fleet would rather see what actually arrives and react than ship
a bound nobody has measured. `deploy/Caddyfile` ships the
`(ratelimit)` snippet and its `import` line **commented out**, the box runs
exactly that file, and `deploy-caddy.sh --apply` verifies on the wire that no
429 comes back during a 75-request burst.

The snippet is **kept, not deleted** -- reacting to what arrives is removing
the default, not forswearing protection. What follows is the analysis you need
to decide whether to reach for it, and the numbers that say why there is no
default. None of it is a runbook step.

**What the limiter would be for.** `POST /kiosk/auth/register` runs the PoW gate
**unauthenticated**, before any key verification: anyone can take a free 402
challenge and resubmit it with a valid HMAC sig and garbage indices. PoW prices
the attacker's **solve**; it never prices our **verify**. And at the shipped
`WEB_CONCURRENCY=1` a plain flood of *any* endpoint -- a 404, the 402 issue path
itself -- saturates the single worker just as well, so only something in FRONT
of the app bounds the request RATE.

**Why it is off anyway, measured.** A proof verifies in **4.46 ms** at the
params the fleet runs. One worker completes a full registration **60 times a
second** and a plain read **1075 times a second**. The snippet as shipped is
**one request a second** (60 events a minute), keyed per-IP in a single zone
shared by every vhost -- so bursting one demo refuses the other seven, which is
a self-inflicted outage on the traffic these demos exist to receive. The app-side
half of the exposure is what changes the arithmetic: an issued challenge drives
at most one verify, and the
verifier checks cheapest-first and hashes lazily, so a garbage proof costs
**0.30 ms** -- 0.012 ms if the attacker did not even order the indices --
instead of the **18.7 ms** it cost when every proof paid the full 128-hash loop.
A real proof still costs ~18 ms. Worker saturation on this path moved from ~54
req/s to ~3.3k req/s.

**If the box actually falls over, two options, either is fine.**

- **Caddy module:** `caddy add-package github.com/mholt/caddy-ratelimit` (Caddy
  >= 2.7 swaps in a plugin-included binary from the official download API --
  Caddy flags the subcommand EXPERIMENTAL, so `xcaddy build --with
  github.com/mholt/caddy-ratelimit` is the stable equivalent if you compile your
  own), then uncomment `import ratelimit` and the `(ratelimit)` snippet in
  `deploy/Caddyfile` -- **in the repo**, and deploy it, not by hand on the box.
  They ship commented because `rate_limit` is not a stock directive: a stock
  binary refuses the whole config ("unrecognized directive: rate_limit") and
  would not start at all, so the module has to be installed first.
- **CDN / WAF** in front of the box (Cloudflare et al.) with a per-IP rate rule
  on `/kiosk/*`. Nothing on this box can see that one, so write down that you
  did it.

**And pick a bound from a measurement.** The snippet as shipped is 60 events a
minute -- one request a second -- against a worker that serves 1075 reads a
second, and nothing anywhere records a measurement behind that number. Whatever
you turn on, burst the origin first and find the rate at which it actually
degrades.

**How this posture is checked.** Nothing here parses the installed config
looking for a `rate_limit` directive. An assertion that the limiter is PRESENT
is the wrong direction while there is no default throttle, and an assertion that
it is ABSENT would go red the day someone correctly turns it back on -- so the
check is not a config parse at all. It is `deploy-caddy.sh`, which compares the
WHOLE file against the box and probes the live wire, so a divergence in either
direction shows up as a diff. Its `--self-test` holds the repo posture (HSTS
declared, limiter not enabled) and runs in CI.

## HSTS -- live on all eight origins

**Measured 2026-09-06, every origin `deploy/Caddyfile` declares: all 8 answer
`strict-transport-security: max-age=31536000; includeSubDomains`.**
`deploy/check-live-hsts.sh` exits 0, 8 of 8.

**It gets there by the deploy, not by a checklist tick, and that distinction is
the mechanism.** `deploy/Caddyfile`'s `(kioskproxy)` snippet emits the header,
enabled and needing no module, and `deploy-caddy.sh` installs this file whole:
**the repo is the source of truth and a deploy is what makes the box match
it**. The header cannot be pasted onto the box, because the next `--apply`
overwrites the file it was pasted into.

What the header buys is one request: `config.force_ssl` is deliberately OFF in
every app behind this proxy (Caddy already terminates TLS and redirects
`:80`→`:443`, and the apps run with `assume_ssl`), so without HSTS a client
typing a bare hostname makes its FIRST request in plaintext, before the
redirect. That first request is the window HSTS closes and the only thing this
line buys.

Re-check it any time, from anywhere, no ssh needed:

<!-- fence-count: 8 ¦ from: git ls-files 'deploy/env/*.env.example' | wc -l -->
```sh
deploy/check-live-hsts.sh          # must print OK for all 8
```

`preload` is deliberately absent: submitting to the browser preload list is
irreversible on any useful timescale and these are demo hosts. `max-age` is one
year, the value the preload list requires and the value a browser should be
willing to remember; `includeSubDomains` covers a sub-subdomain nobody has
created yet, and if one is ever added it must serve TLS.

**Why a script and not a checklist line, said plainly.** The other half of this
class -- the edge rate limit -- got a script and it landed; HSTS got a line in
<!-- count: 47 ¦ from: grep -c '^ *- \[ \]' deploy/CHECKLIST.md -->
`CHECKLIST.md`, whose 47 boxes are unticked in the repository and always
will be — the tracked copy is a template and an operator ticks their own —
so its tick state carried no information at all. `check-live-hsts.sh` reads the WIRE rather than a config,
because a config check run against this template would have said OK for the
whole month the box was serving without the header -- and a deploy proves the
header arrived at the moment it ran, which is a different question from whether
it still arrives now.

**`kiosk.tech` itself is a different owner's setting.** It answers no HSTS
either, but it is served by GitHub Pages, not by this box -- nothing in this
directory can fix it, and `check-live-hsts.sh` only reports it if you pass the
hostname explicitly.


## Scaling past one worker — shared stores REQUIRED

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

> **Card-setup Checkout can show "Something went wrong" if a relaying agent truncates the link.**
> `payment_setup` returns a valid Stripe `mode:setup` `setup_url` — a long
> `checkout.stripe.com/c/pay/<id>#fid…` whose ~500-char `#fid…` fragment Stripe REQUIRES to
> render. The failure is an AGENT relaying that url to the human and DROPPING the fragment (an
> LLM truncating a long opaque string; proven from a live agent's message store) — NOT our code,
> the session, or the Stripe account (deploy and local dev share one account; the session is a
> valid `status:open`). Mitigation: the agent skill instructs assistants to relay the `setup_url`
> VERBATIM and in full, never truncating the part after `#`. If truncation still recurs, the
> robust escalation is an operator-hosted short redirect link.

## Poke it — the "curl one-liner"

Three documents are always free: the top-level **discovery** document, and the
two catalogue documents `GET /kiosk/schema` and `GET /kiosk/openapi.json` — no
Bearer, no toll, and `Cache-Control: max-age=60, public` so a poker (or an
assistant) can read what the origin offers before it registers. Everything else
— every query, every action, `pay` — needs a Bearer token and MAY toll
proof-of-work, and so may `register`. So the register gate is a memory-hard PoW
by design, and the "true" one-liner ships a copy-paste **solver**
(`kiosk-pow-equihash/solve.py`). Hosted difficulty is
`KIOSK_POW_DIFFICULTY=low` (n=96 k=5, ~0.2 s) in every `deploy/env/*.env.example`
but atablefor's, which is intentionally ~9–10 s on an M-series laptop core, the
only hardware either figure has ever been measured on — both rows of
`kiosk-pow-equihash/bench/README.md`'s measured grid, which is where to re-run
them for your own machine (you'll feel the high one — that's the point). Flow:
**discover (free) → read the schema (free) → register (solve PoW) → call a verb
(each MAY toll PoW too)**.

```sh
# 0. Discover: who/where/which capabilities. Free — no auth, no PoW, same as the
#    schema in step (d). (The queries and actions in (e)/(f) are NOT free: each
#    needs a Bearer token and MAY answer 402 pow_required — solve and retry.)
curl -s https://getgrocery.demo.kiosk.tech/.well-known/kiosk.json | jq .

# 1. Full flow — register with the bundled solver, then read schema + query.
#    Needs curl, jq, openssl, uuidgen and python3+numpy; run it from the repo
#    root, since the solver is referenced by a repo-relative path. Everything
#    down to and including (e) was EXECUTED against the hosted origin exactly
#    as written before being published here.
BASE=https://getgrocery.demo.kiosk.tech

#    Two helpers. `b64url` is JWS base64url; `proofs_for` turns a 402 problem
#    document read on STDIN into the `Kiosk-PoW` header value. Note where the
#    challenge goes: the solver takes it as its ARGUMENT and reads nothing on
#    stdin, so a pipe into it prints a usage error and exits 1.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
proofs_for() { jq -c '.challenges[]' | while read -r c; do
    jq -cn --argjson challenge "$c" \
           --argjson nonce "$(python3 kiosk-pow-equihash/solve.py "$c")" \
           '{challenge:$challenge,nonce:$nonce}'   # ~0.2 s low / ~9–10 s high on an M-series core (atablefor)
  done | jq -sc .; }

#    a) an agent keypair, and a challenge nonce FOR THAT KEY. `public_key` is
#       required — without it the endpoint answers 400 — and what comes back is
#       a proof-of-POSSESSION nonce. The PoW challenge arrives later, in (c).
AGENT=$(mktemp -d)   # the keypair lives here, NOT in your checkout
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$AGENT/agent.pem"
openssl rsa -in "$AGENT/agent.pem" -pubout -out "$AGENT/agent.pub"
NONCE=$(curl -sG --data-urlencode "public_key@$AGENT/agent.pub" \
  "$BASE/kiosk/auth/challenge" | jq -r .challenge)

#    b) sign the proof of possession: an RS256 JWS carrying (a)'s nonce, with
#       `aud` = the origin YOU dialed. That binding is the relay defence — a
#       proof signed for one origin is worthless at another.
H=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
P=$(printf '{"aud":"%s","nonce":"%s","jti":"%s","iat":%s}' \
     "$BASE" "$NONCE" "$(uuidgen)" "$(date +%s)" | b64url)
POP="$H.$P.$(printf '%s.%s' "$H" "$P" | openssl dgst -sha256 -sign "$AGENT/agent.pem" -binary | b64url)"
BODY=$(jq -n --rawfile pk "$AGENT/agent.pub" --arg s "$POP" '{public_key:$pk, signed:$s}')

#    c) register → the token. The first POST answers 402 `pow_required` with
#       the Equihash challenge(s); solve them and re-send the SAME body with
#       the proof in the `Kiosk-PoW` HEADER, never in the body — the signed
#       body may not change, or the proof no longer covers what you sent.
REG=$(curl -s -X POST "$BASE/kiosk/auth/register" \
  -H 'content-type: application/json' -d "$BODY")
TOKEN=$(curl -s -X POST "$BASE/kiosk/auth/register" \
  -H 'content-type: application/json' \
  -H "Kiosk-PoW: $(printf '%s' "$REG" | proofs_for)" \
  -d "$BODY" | jq -r .access_token)

#    d) read the schema — PUBLIC and cacheable, so no Bearer and no toll here;
#       this one answers just as well before step (c) as after it.
curl -s "$BASE/kiosk/schema" | jq .

#    e) call a query as the registered assistant — protocol 0.4: one endpoint
#       per verb, a query is a GET whose arguments are the query string, and the
#       success body IS the result: a bare JSON array, no envelope to unwrap
#       (the matching-row count rides in the X-Total-Count response header).
#       Bearer required, and on the hosted origins this one DOES toll: the
#       first call answers 402, and the retry is the SAME request with the
#       proof in the Kiosk-PoW header — the pattern register just used.
CAT=$(curl -s "$BASE/kiosk/catalog" -H "authorization: Bearer $TOKEN")
curl -s "$BASE/kiosk/catalog" -H "authorization: Bearer $TOKEN" \
  -H "Kiosk-PoW: $(printf '%s' "$CAT" | proofs_for)" | jq .

#    f) …and an action is a POST at its own path, with the arguments as the body,
#       tolled the same way (wrap it in the (e) retry if it answers 402).
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
> returns and `solve.py` consumes, and the block above is the copy-paste form of
> it. It is the only one: no demo landing page carries a curl one-liner.
> atablefor shows the
> "beware: memory- and CPU-intensive PoW" banner so pokers expect the ~9–10 s
> (measured on an M-series laptop core; other hardware differs).

