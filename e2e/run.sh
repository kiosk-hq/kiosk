#!/usr/bin/env bash
# Kiosk OSS — end-to-end test harness.
#
# Same script runs locally and in CI. Builds a fresh Rails app from
# scratch, installs Kiosk via path overrides, runs the kiosk:install
# generator, applies migrations, seeds, starts the server, drives a
# mock-AI-assistant script against REST endpoints, asserts on results,
# tears down.
#
# Prereqs:
#   - Ruby with bundler (no version is checked; ci.yml's e2e job names the
#     one CI runs)
#   - Postgres reachable (default host: $PGHOST or localhost)
#   - rails gem (the script will install if missing)
#
# Usage:
#   ./e2e/run.sh
#
# Env:
#   KIOSK_OSS       — path to the reference monorepo root (defaults to script's parent dir)
#   PGHOST          — Postgres host (default: localhost)
#   SERVER_PORT     — port for the started Rails app (default: 3001)

set -euo pipefail

# ─── setup ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KIOSK_OSS="${KIOSK_OSS:-$( cd "$SCRIPT_DIR/.." && pwd )}"

# ─── mise (Ruby version manager) ────────────────────────────────────────
# Export mise environment — no cd hooks, persists across directories.
if command -v mise >/dev/null 2>&1; then
  mise trust "$KIOSK_OSS"  >/dev/null 2>&1 || true
  mise trust "$SCRIPT_DIR" >/dev/null 2>&1 || true
  eval "$(mise env -s bash)"
fi

# Put the active Ruby's gem bindir first, so `rails`/`bundle` resolve to the
# gems installed under this Ruby — not the macOS system stub at /usr/bin/rails
# (which exits 0 with a "Rails is not installed" message and fools pre-flight).
if command -v ruby >/dev/null 2>&1; then
  GEM_BINDIR="$(ruby -e 'print Gem.bindir' 2>/dev/null || true)"
  [ -n "$GEM_BINDIR" ] && PATH="$GEM_BINDIR:$PATH" && export PATH
fi
SERVER_PORT="${SERVER_PORT:-3001}"
DB_NAME="kiosk_e2e_$$"
APP_NAME="demo_app"
TMP_DIR="$(mktemp -d -t kiosk-e2e.XXXX)"
SERVER_PID=""
# The origin's log. Named UNIQUELY PER INVOCATION and read back through this
# variable, never through a re-typed literal: a fixed `/tmp` path is shared
# with every process on the machine and survives between runs, so a `tail` of
# it can show a PREVIOUS run's failure as though it were this one's.
# It is deliberately NOT under $TMP_DIR, which `cleanup` removes — a post-mortem
# wants the whole log after the run has ended, so the failure paths below name
# the path instead of leaving it to be guessed.
SERVER_LOG="/tmp/kiosk-e2e-server.$$.log"

# Make rails/bundle available even if gem-bin-dir isn't on PATH.
GEM_BIN="$(gem env 2>/dev/null | awk -F': ' '/EXECUTABLE DIRECTORY/ {print $2}')"
[ -n "$GEM_BIN" ] && export PATH="$GEM_BIN:$PATH"

log() { printf "\n\033[1;36m==>\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m  ✓\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m  ✗\033[0m %s\n" "$*"; exit 1; }

cleanup() {
  log "cleanup"
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # Both databases, not just the one this harness names: `rails db:create`
  # creates the CURRENT environment's database AND the test one, so every run
  # also lays down ${DB_NAME}_test (see the database.yml written below). CI
  # throws the container away and never noticed; on a developer machine the
  # test halves accumulate one per run unless they are dropped here.
  psql -d postgres -tAc "DROP DATABASE IF EXISTS $DB_NAME" >/dev/null 2>&1 || true
  psql -d postgres -tAc "DROP DATABASE IF EXISTS ${DB_NAME}_test" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# ─── pre-flight ─────────────────────────────────────────────────────────

log "pre-flight: ruby, bundler, rails, postgres"

command -v ruby     >/dev/null || fail "ruby not on PATH"
command -v bundle   >/dev/null || fail "bundler not on PATH"
# `rails --version` on a real gem prints "Rails <n>"; the macOS system stub at
# /usr/bin/rails prints "Rails is not currently installed…" and exits 0, so
# match a version digit specifically. Install into the active gem home if absent.
if ! rails --version 2>/dev/null | grep -qE '^Rails [0-9]'; then
  log "rails gem missing — installing into $(ruby -e 'print Gem.dir')"
  gem install rails --no-document
  hash -r  # forget the cached /usr/bin/rails so the fresh binstub is picked up
fi
rails --version 2>/dev/null | grep -qE '^Rails [0-9]' || fail "rails still not resolvable (got: $(rails --version 2>&1 | head -1))"
command -v psql     >/dev/null || fail "psql not on PATH"
command -v curl     >/dev/null || fail "curl not on PATH"
command -v jq       >/dev/null || fail "jq not on PATH"
# The golden path registers with a real register-time Equihash PoW, solved by
# the bundled numpy-vectorised solver (kiosk-pow-equihash/solve.py).
command -v python3  >/dev/null || fail "python3 not on PATH (needed by the Equihash register-PoW solver)"
python3 -c "import numpy" 2>/dev/null || fail "python numpy missing (pip install numpy) — needed by the Equihash register-PoW solver"
# The event-stream leg runs the PINNED listener — the same file an assistant
# fetches from kiosk.tech and verifies by SHA-256 — so the harness needs what
# that file needs. `websockets` is one pure-Python package with no transitive
# dependencies; the alternative measured at 2.8x the code, 117 lines of it a
# hand-rolled RFC 6455 frame parser.
#
# IT GETS ITS OWN INTERPRETER KNOB, and the reason is the one every macOS
# developer meets: PEP 668 makes a Homebrew or system python refuse
# `pip install` outright, so «just install it» is not available there. The
# skill already tells an assistant to make a venv for `pyjwt`, `cryptography`
# and `numpy`; `KIOSK_PYTHON` is how this harness is pointed at one. The
# SOLVER keeps using plain `python3` — numpy is normally installed system-wide
# and the two requirements are separate.
KIOSK_PYTHON="${KIOSK_PYTHON:-python3}"
command -v "$KIOSK_PYTHON" >/dev/null || fail "KIOSK_PYTHON=$KIOSK_PYTHON is not on PATH"
"$KIOSK_PYTHON" -c "import websockets" 2>/dev/null || fail "python websockets missing — needed by the pinned event-stream listener. Either install it (pip install 'websockets>=12') or point the harness at an interpreter that has it: python3 -m venv .venv && .venv/bin/pip install 'websockets>=12' && KIOSK_PYTHON=.venv/bin/python ./e2e/run.sh"

pg_isready -q || fail "postgres not accepting connections (run: brew services start postgresql)"

[ -d "$KIOSK_OSS/kiosk-core" ] || fail "KIOSK_OSS=$KIOSK_OSS missing kiosk-core (set KIOSK_OSS to the reference monorepo root)"

ok "all prerequisites present"

# Pre-create app_role so Kiosk.configure app_role= / system_role= reference
# a real PG role. NOLOGIN + grant to current user is harmless forward-compat:
# Path C uses app-layer isolation (named queries), not RLS, and this fixture
# exercises no role separation at all — see e2e/README.md.
psql -d postgres -tAc "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role') THEN
    CREATE ROLE app_role NOLOGIN;
  END IF;
END \$\$;" >/dev/null
psql -d postgres -tAc "GRANT app_role TO CURRENT_USER" >/dev/null
ok "PG role 'app_role' present"

# ─── rails new ──────────────────────────────────────────────────────────

log "rails new $APP_NAME in $TMP_DIR"
cd "$TMP_DIR"
# The generator's output is noise on success and the ONLY diagnosis on failure,
# so it goes to a per-invocation log whose tail the fail branch prints —
# the shape deploy/production-smoke.sh and deploy/demo-reset.sh already use. It is
# deliberately NOT the re-run-with-output shape used for `db:create db:migrate
# db:seed` below: that step is safe to repeat, whereas re-running `rails new` over
# a half-generated app hits Thor's file-collision prompt and would hang a CI run
# instead of diagnosing it. Discarding both streams was what left the `cd` on the
# next line to fail on a directory that was never created, so the run died on the
# symptom and never printed the cause.
GEN_LOG="$(mktemp -t kiosk-e2e-rails-new.XXXXXX)"
rails new "$APP_NAME" --skip-bundle -d postgresql --skip-test --api --skip-git \
  >"$GEN_LOG" 2>&1 || {
    printf '  ---- last 30 lines of %s ----\n' "$GEN_LOG"
    tail -n 30 "$GEN_LOG" | sed 's/^/  | /'
    fail "rails new failed (full output stays at $GEN_LOG)"
  }
rm -f "$GEN_LOG"
cd "$APP_NAME"
ok "$APP_NAME generated"

# ─── Gemfile patch (path overrides) ─────────────────────────────────────

# THE DELIMITER IS QUOTED, AND THAT IS LOAD-BEARING. With an
# UNQUOTED `<<RUBY` the shell runs parameter expansion AND COMMAND
# SUBSTITUTION over the heredoc BODY before writing it -- so a backticked
# span in a COMMENT is executed. It was: every run of this harness printed
#   e2e/run.sh: line NNN: c.validate_requests: command not found
#   e2e/run.sh: line NNN: add_dependency: command not found
# on stderr while run.sh still exited 0, and the two comments below reached
# the generated Gemfile with the backticked text replaced by the empty
# output of the command that failed. Prose in a generated file is prose;
# nothing in it may be executable, and the next comment someone writes here
# must not be able to run anything.
#
# The one value that has to vary is the sibling-checkout path, and it is
# spliced in AFTERWARDS, by Ruby, on an unmistakable placeholder -- so no
# shell expansion is needed in this body at all. Ruby is already a hard
# prerequisite of this script, and a literal string gsub has no
# metacharacter of its own to get wrong. A replacement STRING does: sed
# and Ruby's own String#sub both read `&` and a backslash-digit in the
# REPLACEMENT as backreferences, and a path is attacker-shaped input the
# day someone runs this from a directory with a `&` in its name -- hence
# gsub's BLOCK form below, which takes the path as a literal.
cat >> Gemfile <<'RUBY'

# Kiosk OSS gems via path overrides (sibling clone of kiosk-hq/kiosk).
# kiosk-rls is REQUIRED even though this fixture does not use RLS: it is the
# only source of Configuration#system_role=, which initializer_kiosk.rb sets.
# Dropping it makes the initializer raise NoMethodError at boot.
# kiosk-reputation + kiosk-pow-equihash back the register-time Equihash PoW
# gate (registration_pow_count=1 in the initializer); neither is a transitive
# dep of kiosk-all, so both must be path-overridden explicitly (same as demos).
gem "kiosk-all",           path: "@KIOSK_OSS@/kiosk-all"
gem "kiosk-core",          path: "@KIOSK_OSS@/kiosk-core"
gem "kiosk-rls",           path: "@KIOSK_OSS@/kiosk-rls"
gem "kiosk-server",        path: "@KIOSK_OSS@/kiosk-server"
gem "kiosk-reputation",    path: "@KIOSK_OSS@/kiosk-reputation"
gem "kiosk-pow-equihash",  path: "@KIOSK_OSS@/kiosk-pow-equihash"
gem "kiosk-user-idp-devise", path: "@KIOSK_OSS@/kiosk-user-idp-devise"
# kiosk-redteam ships Kiosk::Redteam::Wire.http_for, the one place this
# repository decides http vs https. The fixtures and schema_conformance.rb open
# their sockets through it, so SERVER_URL may name a deployed TLS origin and
# not only this harness's own localhost app.
gem "kiosk-redteam",       path: "@KIOSK_OSS@/kiosk-redteam"

# Devise backs the HUMAN half of the account-binding ceremony. The adapter above
# only reads the request's Warden user, so the provider's own Devise install is
# what satisfies it — which is why both lines are here rather than one.
gem "devise"

# json_schemer backs `c.validate_requests = true` in the initializer, which is
# what makes a verb's declared input_schema EXECUTABLE — the arguments of a
# per-verb request are validated against it, not merely published. It is a
# RUNTIME dependency of kiosk-server (`add_dependency`), so
# Bundler resolves it for any host that depends on the gem; it is named here
# anyway because this Gemfile is generated for a from-scratch app and naming
# what the initializer relies on is the point of the file. It is only lazily
# REQUIRED — the flag being off loads nothing — and a bundle that somehow does
# not carry it raises a ConfigurationError naming the gem at the first
# validation, deliberately fail-loud.
gem "json_schemer"
RUBY

# Splice the sibling-checkout path into the block just written. Fails loudly
# when the placeholder is gone: a substitution that silently matches nothing
# would leave a literal placeholder in the Gemfile and `bundle install` would
# fail somewhere far away from the cause.
SPLICED="$(ruby -e '
  path, file = ARGV
  src = File.read(file)
  hits = src.scan("@KIOSK_OSS@").size
  abort "no @KIOSK_OSS@ placeholder in #{file} -- the Gemfile block did not get written" if hits.zero?
  File.write(file, src.gsub("@KIOSK_OSS@") { path })
  puts hits
' "$KIOSK_OSS" Gemfile)" || fail "could not splice KIOSK_OSS into the generated Gemfile"
ok "Gemfile written verbatim; $SPLICED path override(s) point at $KIOSK_OSS"

log "bundle install (this can take a moment on a cold cache)"
bundle install --quiet
ok "bundle complete"

# ─── DB config ──────────────────────────────────────────────────────────

# UNQUOTED on purpose, unlike the Gemfile block above: this body is
# three deliberate expansions and no prose, so there is nothing here for
# command substitution to reach. THE MOMENT A COMMENT GOES IN, quote the
# delimiter and splice the values the way that block does -- a backtick in a
# YAML comment would run, and the only symptom would be a line on stderr
# under an exit 0.
cat > config/database.yml <<YML
default: &default
  adapter: postgresql
  encoding: unicode
  pool: 5
  host: ${PGHOST:-localhost}

development:
  <<: *default
  database: $DB_NAME

test:
  <<: *default
  database: ${DB_NAME}_test
YML

# ─── fixtures + generator ───────────────────────────────────────────────

log "stage fixtures + run kiosk:install generator"

FIXTURES="$KIOSK_OSS/e2e/fixtures"
# 1) Users migration (must precede kiosk:install — kiosk-server's identity
# tables FK to users(id)). Rails creates db/migrate/ lazily, so mkdir
# first.
mkdir -p db/migrate
ts1="20260101000000"
cp "$FIXTURES/create_users.rb" "db/migrate/${ts1}_create_users.rb"
# 1b) The Devise login columns on that same table. Its timestamp must sort
# AFTER create_users and BEFORE the generator's (which use Time.now).
ts1b="20260101000001"
cp "$FIXTURES/add_devise_columns_to_users.rb" "db/migrate/${ts1b}_add_devise_columns_to_users.rb"

# 2) Generator-produced migrations.
bundle exec rails g kiosk:install --user-id-type=uuid >/dev/null

# 3) Demo schema (salons + appointments + RLS). Timestamp = now + 60s —
# enough to run after the kiosk:install migrations (which use Time.now)
# while staying inside Rails's «migration timestamp ≤ now + 1day» check.
ts3=$(ruby -e "puts (Time.now + 60).utc.strftime('%Y%m%d%H%M%S')")
cp "$FIXTURES/create_salons_and_appointments.rb" \
   "db/migrate/${ts3}_create_salons_and_appointments.rb"

# 4) Models, seeds, app services, initializer, routes. No agent IdP is staged
# (see the note below).
# `rails new --api` generates ApplicationController < ActionController::API, and
# Devise's controllers inherit from it — the sign-in form 500s on `flash`, which
# ::API does not have. This is the controller half of leaving api_only behind
# (the middleware half is the config.api_only patch below).
cp "$FIXTURES/application_controller.rb" app/controllers/application_controller.rb
# The salon's back office: one operator-side page, OUTSIDE the mount and
# outside `c.handlers`, that marks an appointment confirmed and pushes the
# `appointment_confirmed` topic. It is what makes the event-stream leg a PUSH
# rather than a reply — nothing the assistant calls produces that transition.
cp "$FIXTURES/salon_desk_controller.rb" app/controllers/salon_desk_controller.rb
cp "$FIXTURES/user.rb"               app/models/user.rb
cp "$FIXTURES/salon.rb"              app/models/salon.rb
cp "$FIXTURES/appointment.rb"        app/models/appointment.rb
cp "$FIXTURES/seeds.rb"              db/seeds.rb
# The three wire verbs are ordinary Rails controllers, named in
# `c.handlers` in the initializer below. `rails new --api` does not create
# app/controllers/kiosk/, so make it before copying into it.
mkdir -p app/controllers/kiosk
cp "$FIXTURES/catalog_controller.rb"  app/controllers/kiosk/catalog_controller.rb
cp "$FIXTURES/bookings_controller.rb" app/controllers/kiosk/bookings_controller.rb
# The adapters the initializer hands to `Kiosk.configure` are APPLICATION code,
# so they go under app/ — not into lib/ behind a hand-written
# `require Rails.root.join("lib/...")`. `rails new --api` does not create
# app/services either.
#
# THERE IS NO AGENT-IdP AMONG THEM, and that is the point: the engine's own
# DefaultAgentIdp — the adapter that verifies the tokens the engine mints — is
# what authenticates assistants, with nothing configured.
mkdir -p app/services
cp "$FIXTURES/stub_psp.rb"           app/services/stub_psp.rb
# The operator's audit sink. Kiosk stores no audit trail — it emits one
# event per action invocation to whatever callable `c.audit_sink` names, and
# this is that callable, written the way an adopter would write it.
cp "$FIXTURES/demo_audit_sink.rb"    app/services/demo_audit_sink.rb
cp "$FIXTURES/initializer_kiosk.rb"  config/initializers/kiosk.rb
cp "$FIXTURES/devise_initializer.rb" config/initializers/devise.rb
cp "$FIXTURES/routes.rb"             config/routes.rb
# The wire surface itself, in its own file — the ninth showcase of what every
# demo now does: config/routes.rb reaches it with Rails' own
# `draw(:kiosk)`, it mounts the engine for the protocol plane, and it draws one
# explicit route per registered verb with the method following the kind.
mkdir -p config/routes
cp "$FIXTURES/routes_kiosk.rb"       config/routes/kiosk.rb

# …and app/services is declared an autoload-ONCE path, which is what lets the
# initializer name those four with no `require` at all. Rails sets the
# reloadable autoloader up in its `finisher`, AFTER config/initializers run, so
# an ordinary autoload path is not resolvable from an initializer — in lib/ or
# in app/. The once autoloader is set up in `bootstrap`, before them. This is
# the same line every demo carries, and the harness patches the GENERATED
# application.rb so an adopter reading run.sh sees the one edit it takes.
ruby -e '
  path = "config/application.rb"
  src  = File.read(path)
  anchor = /^(\s*)config\.load_defaults .*\n/
  abort "e2e: could not find config.load_defaults in #{path}" unless src =~ anchor
  indent = Regexp.last_match(1)
  line = "#{indent}config.autoload_once_paths << Rails.root.join(\"app/services\").to_s\n"
  File.write(path, src.sub(anchor) { |m| m + line })
' || fail "could not declare app/services as an autoload-once path"

# …and the app leaves api_only behind. The account-binding ceremony runs on a
# real browser session — the human signs in through the Devise form and the
# verify/link/unlink surfaces read that session cookie — so cookies, session and
# flash middleware must be present. `rails new --api` turns them off; this is the
# one line it takes to turn them back on, and an adopter scaffolding from --api
# needs to see it. The agent-facing wire controllers stay ActionController::API
# inside kiosk-server and are unaffected.
ruby -e '
  path = "config/application.rb"
  src  = File.read(path)
  abort "e2e: could not find config.api_only in #{path}" unless src =~ /^\s*config\.api_only\s*=\s*true\s*$/
  File.write(path, src.sub(/^(\s*)config\.api_only\s*=\s*true\s*$/) { "#{Regexp.last_match(1)}config.api_only = false" })
' || fail "could not turn api_only off for the Devise session middleware"

# …and the harness's env inputs are PUBLISHED from the generated environment
# files rather than resolved in the initializer. THE SPLIT IS FLEET-WIDE:
# env-var reading, dev/test fallbacks and crash-if-absent fetches live in
# config/environments/* as Rails custom config, and initializers READ
# `Rails.configuration.x.kiosk.*`. All seven demos carry it, and this harness
# — which e2e/README.md presents as the edits an adopter makes — carries it too. The variables themselves stay honourable from the outside:
# this script exports KIOSK_ISSUER and the audit-sink paths before each boot and
# the block below is what reads them.
# BOTH files get the SAME block: the harness only ever boots development, but
# KIOSK_POW_SECRET must still fail loud if the app is booted outside it, which
# a development-only block could not do.
KIOSK_ENV_BLOCK="$FIXTURES/environment_kiosk.rb" ruby -e '
  block = File.read(ENV.fetch("KIOSK_ENV_BLOCK"))
  %w[development production].each do |env|
    path = "config/environments/#{env}.rb"
    src  = File.read(path)
    abort "e2e: could not find the closing end in #{path}" unless src =~ /\nend\s*\z/
    File.write(path, src.sub(/\nend\s*\z/, "\n" + block + "end\n"))
  end
' || fail "could not publish the Kiosk env inputs into the generated environment files"

ok "fixtures + generator output staged"

# ─── DB setup ───────────────────────────────────────────────────────────

log "rails db:create db:migrate db:seed"
bundle exec rails db:create db:migrate db:seed RAILS_ENV=development \
  >/dev/null 2>&1 || {
    log "rails db setup failed — re-running with output for diagnosis"
    bundle exec rails db:create db:migrate db:seed RAILS_ENV=development
    fail "rails db setup failed"
  }
ok "schema + seeds applied"

# ─── DB-level dedupe of live agent keys ─────────────────────────────────
# Prove the partial UNIQUE index (public_key WHERE revoked_at IS NULL)
# rejects a SECOND live agent row for one key at the DB level — not via a
# TOCTOU SELECT-then-INSERT. A revoked row for the same key is allowed.
log "assert DB-level uniqueness on kiosk.agents.public_key (live rows)"
REGISTER_DUP_KEY="register-dup-$$"
# STDOUT only. `-qtA` prints row counts nobody reads, but ON_ERROR_STOP reports
# the constraint name, a missing pgcrypto or a typo in the SQL below on STDERR —
# and the one-sentence `fail` message cannot reconstruct any of them, so stderr
# is let through. Costs no noise on the success path: there is none.
psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -qtA >/dev/null <<SQL || fail "live-key uniqueness setup insert failed"
  INSERT INTO users (id, created_at, updated_at) VALUES (gen_random_uuid(), now(), now());
  INSERT INTO kiosk.agents (user_id, allowed_roles, public_key)
    SELECT id, ARRAY['customer']::text[], '$REGISTER_DUP_KEY' FROM users LIMIT 1;
SQL
# Second LIVE insert of the same key must be REJECTED by the unique index.
# THE ONE PLACE `2>&1` IS CORRECT AND MUST STAY: this is the NEGATIVE
# CONTROL, so Postgres's unique-violation message is what SUCCESS looks like —
# printing it would make a passing run read as broken. Do not "fix" this line to
# match the two around it, which discard a diagnostic instead of an expectation.
if psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -qtA >/dev/null 2>&1 <<SQL
  INSERT INTO kiosk.agents (user_id, allowed_roles, public_key)
    SELECT id, ARRAY['customer']::text[], '$REGISTER_DUP_KEY' FROM users LIMIT 1;
SQL
then
  fail "a SECOND live agent row with the same public_key was accepted (unique index missing)"
fi
# A revoked row for the same key IS allowed (partial index skips revoked rows).
# stderr let through for the same reason as the setup insert above: if
# the partial index is wrong, Postgres NAMES it and "wrongly rejected" does not.
psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -qtA >/dev/null <<SQL || fail "revoked-key re-insert wrongly rejected"
  INSERT INTO kiosk.agents (user_id, allowed_roles, public_key, revoked_at)
    SELECT id, ARRAY['customer']::text[], '$REGISTER_DUP_KEY', now() FROM users LIMIT 1;
SQL
psql -d "$DB_NAME" -qtA >/dev/null 2>&1 <<SQL || true
  DELETE FROM kiosk.agents WHERE public_key = '$REGISTER_DUP_KEY';
SQL
ok "live-key uniqueness enforced at the DB; revoked key may re-register"

# ─── signing key for JWKS (kiosk-pop JWTs) ──────────────────────────────
log "generate signing key for JWKS (kiosk-pop JWTs)"
SIGNING_KEY_PEM=$(openssl genrsa 2048 2>/dev/null)
export KIOSK_SIGNING_KEY_B64=$(echo "$SIGNING_KEY_PEM" | base64)
ok "signing key generated"

# ─── start server ───────────────────────────────────────────────────────

log "start rails server on port $SERVER_PORT"
export KIOSK_ISSUER="http://127.0.0.1:$SERVER_PORT"
# Where the operator's sink writes. Its PRESENCE is what makes the initializer
# configure a sink at all, so the second boot below (which unsets it) is the
# default-off proof.
AUDIT_EVENTS="$TMP_DIR/audit-events.jsonl"
AUDIT_EVENTS_REDACTED="$TMP_DIR/audit-events-redacted.jsonl"
export KIOSK_AUDIT_SINK_FILE="$AUDIT_EVENTS"
export KIOSK_AUDIT_SINK_REDACTED_FILE="$AUDIT_EVENTS_REDACTED"
bundle exec rails s -p "$SERVER_PORT" -b 127.0.0.1 -e development \
  > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Wait for readiness — max 30s.
ready=0
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$SERVER_PORT/.well-known/kiosk.json" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

[ $ready -eq 1 ] || {
  tail -50 "$SERVER_LOG"
  fail "server did not become ready on http://127.0.0.1:$SERVER_PORT (see log above; full log: $SERVER_LOG)"
}
ok "server up on http://127.0.0.1:$SERVER_PORT"

# ─── mint the two agent principals, by ceremony ─────────────────────────────
#
# THE SUITE EARNS ITS PRINCIPALS the way a real assistant does, because there is
# no parser anywhere that would believe a self-asserted one: an Equihash-tolled
# `/auth/register` (a HEADLESS account), the
# human's link code minted on a real Devise session, and `/auth/claim` — which
# rebinds the key to that human and returns the token every assertion below
# rides. Two of them, one for alice and one for bob, because the isolation
# assertions need two principals that are genuinely different people.
log "bind two assistants to the seeded humans (register -> link -> claim)"
bind_json=$( cd "$PWD" && SERVER_URL="http://127.0.0.1:$SERVER_PORT" \
               KIOSK_ISSUER="$KIOSK_ISSUER" HUMAN_PASSWORD="e2e-demo-password" \
               bundle exec ruby "$FIXTURES/bind_assistants.rb" ) \
  || fail "the binding ceremony did not produce two assistants"
export ALICE_AGENT=$(echo "$bind_json" | jq -r '.alice_agent')
export ALICE_AGENT_TOKEN=$(echo "$bind_json" | jq -r '.alice_token')
export BOB_AGENT=$(echo "$bind_json" | jq -r '.bob_agent')
export BOB_AGENT_TOKEN=$(echo "$bind_json" | jq -r '.bob_token')
[ -n "$ALICE_AGENT_TOKEN" ] && [ "$ALICE_AGENT_TOKEN" != "null" ] \
  || fail "no access token for alice's assistant: $bind_json"
[ -n "$BOB_AGENT_TOKEN" ] && [ "$BOB_AGENT_TOKEN" != "null" ] \
  || fail "no access token for bob's assistant: $bind_json"
ok "alice's assistant $ALICE_AGENT and bob's assistant $BOB_AGENT are bound and hold kiosk-pop tokens"

# ─── run the assistant ──────────────────────────────────────────────────

log "run mock AI-assistant test suite"
PAY_CAPTURE="$TMP_DIR/pay-capture.json"
POW_CAPTURE="$TMP_DIR/pow-capture.json"
if ! SERVER_URL="http://127.0.0.1:$SERVER_PORT" \
       APP_DIR="$PWD" \
       FIXTURES="$FIXTURES" \
       DB_NAME="$DB_NAME" \
       KIOSK_ISSUER="$KIOSK_ISSUER" \
       ALICE_AGENT="$ALICE_AGENT" \
       ALICE_AGENT_TOKEN="$ALICE_AGENT_TOKEN" \
       BOB_AGENT="$BOB_AGENT" \
       BOB_AGENT_TOKEN="$BOB_AGENT_TOKEN" \
       AUDIT_EVENTS="$AUDIT_EVENTS" \
       AUDIT_EVENTS_REDACTED="$AUDIT_EVENTS_REDACTED" \
       PAY_CAPTURE="$PAY_CAPTURE" \
       POW_CAPTURE="$POW_CAPTURE" \
       KIOSK_OSS="$KIOSK_OSS" \
       TMP_DIR="$TMP_DIR" \
       KIOSK_PYTHON="$KIOSK_PYTHON" \
       bash "$KIOSK_OSS/e2e/assistant.sh"; then
  log "assistant failed — last 80 lines of server log ($SERVER_LOG):"
  tail -80 "$SERVER_LOG"
  exit 1
fi

ok "all assertions passed"

# ─── the §5/§6 ceremonies, driven for their BYTES ───────────────────────────
#
# auth.schema.json and binding.schema.json are vendored beside the other six,
# and this is what produces a byte for them to judge.
# This driver runs kiosk-pop (challenge → register → login → revoke) and both
# binding directions (link → claim → unlink, and the RFC 8628 device grant with
# a real human approving on the real verify page) and writes down the requests
# and the answers; the schema step below validates all thirteen objects.
#
# AFTER the assistant, not before: the ceremonies mint a third agent for alice,
# rebind it twice and deactivate it, and every assertion about alice and bob is
# already made by this point. The audit-sink row counts are taken later still,
# so this driver's residue cannot be read as the sink's.
log "drive the §5/§6 auth and binding ceremonies (for their live bytes)"
AUTH_CAPTURE="$TMP_DIR/auth-capture.json"
auth_capture_out=$( SERVER_URL="http://127.0.0.1:$SERVER_PORT" \
                      KIOSK_ISSUER="$KIOSK_ISSUER" \
                      HUMAN_EMAIL="alice@example.com" \
                      HUMAN_PASSWORD="e2e-demo-password" \
                      AUTH_CAPTURE="$AUTH_CAPTURE" \
                      bundle exec ruby "$FIXTURES/auth_wire_capture.rb" ) \
  || fail "the §5/§6 ceremonies did not complete"
ok "auth + binding wire bytes captured: $auth_capture_out"

# ─── the published schemas, against the bytes just served ───────────────────
#
# Spec §16.3 anchor 1. The assistant above asserts field by field, in
# this harness's own words; this step asserts the SAME responses against the
# normative JSON Schemas kiosk.tech publishes. The two are different oracles
# and the second is the one an outside implementer can run: a wire that drifts
# from the published schema fails here even when every assertion above still
# passes. Run from the generated app dir
# so json_schemer (a kiosk-server runtime dependency) is on the load path, and
# with the server still up — these are live requests, not a replay.
log "validate live wire bytes against the published JSON Schemas"
if ! SERVER_URL="http://127.0.0.1:$SERVER_PORT" \
       TOKEN="$ALICE_AGENT_TOKEN" \
       PAY_CAPTURE="$PAY_CAPTURE" \
       POW_CAPTURE="$POW_CAPTURE" \
       AUTH_CAPTURE="$AUTH_CAPTURE" \
       bundle exec ruby "$KIOSK_OSS/e2e/schema_conformance.rb"; then
  log "schema conformance failed — last 40 lines of server log ($SERVER_LOG):"
  tail -40 "$SERVER_LOG"
  exit 1
fi

ok "live wire bytes conform to the published schemas"

# ─── the audit sink is OFF by default ───────────────────────────────────────
#
# Everything above ran with `c.audit_sink` SET. The default is nil, and «the
# default emits nothing» is not a claim a suite can make from the side that has
# a sink configured — so the origin is restarted with KIOSK_AUDIT_SINK_FILE
# UNSET, which is what leaves `audit_sink` nil in the initializer, and one real
# action is driven through it. Nothing may be emitted and nothing may be
# written: not to the sink's files, not to any table.

log "restart the origin with NO audit sink configured (the default)"
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
unset KIOSK_AUDIT_SINK_FILE KIOSK_AUDIT_SINK_REDACTED_FILE

events_before=$(wc -l < "$AUDIT_EVENTS" | tr -d ' ')
redacted_before=$(wc -l < "$AUDIT_EVENTS_REDACTED" | tr -d ' ')
# Every row in every table of the kiosk schema, counted through query_to_xml so
# the assertion needs no table list and cannot go stale when one is added.
kiosk_rows() {
  psql -X -d "$DB_NAME" -tAc "
    SELECT COALESCE(SUM(cnt), 0) FROM (
      SELECT (xpath('/row/cnt/text()',
                    query_to_xml(format('SELECT count(*) AS cnt FROM %I.%I', schemaname, relname),
                                 false, true, '')))[1]::text::bigint AS cnt
      FROM pg_stat_user_tables WHERE schemaname = 'kiosk'
    ) t"
}
rows_before=$(kiosk_rows)

bundle exec rails s -p "$SERVER_PORT" -b 127.0.0.1 -e development \
  >> "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
ready=0
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$SERVER_PORT/.well-known/kiosk.json" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[ $ready -eq 1 ] || {
  tail -50 "$SERVER_LOG"
  fail "sink-less origin did not become ready (see log above; full log: $SERVER_LOG)"
}

# The SAME token alice's assistant has been using. This restart shares the
# database and the exported KIOSK_SIGNING_KEY_B64 with the origin above, so the
# kiosk-pop JWT verifies here too — the agent row and the signing key are what
# it is checked against, and neither moved.
SINKLESS_TOKEN="$ALICE_AGENT_TOKEN"
sinkless_salon=$(curl -sS "http://127.0.0.1:$SERVER_PORT/kiosk/salons" \
  -H "Authorization: Bearer $SINKLESS_TOKEN" | jq -r '.[0].id')
sinkless_code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
  "http://127.0.0.1:$SERVER_PORT/kiosk/book_appointment" \
  -H "Authorization: Bearer $SINKLESS_TOKEN" -H "Content-Type: application/json" \
  -d "{\"salon_id\":$sinkless_salon,\"slot\":\"2029-03-03T09:00:00Z\"}")
[ "$sinkless_code" = "200" ] || fail "sink-less origin did not serve the action (got $sinkless_code)"

[ "$(wc -l < "$AUDIT_EVENTS" | tr -d ' ')" = "$events_before" ] \
  || fail "an origin with NO audit sink still wrote to the sink's file"
[ "$(wc -l < "$AUDIT_EVENTS_REDACTED" | tr -d ' ')" = "$redacted_before" ] \
  || fail "an origin with NO audit sink still wrote to the redacted file"
# The action itself wrote an appointment, in `public`. The kiosk schema must be
# untouched: no audit row, because there is nowhere for one to go.
[ "$(kiosk_rows)" = "$rows_before" ] \
  || fail "an origin with NO audit sink wrote $(( $(kiosk_rows) - rows_before )) row(s) into the kiosk schema"
ok "no sink configured ⇒ nothing emitted, nothing written to any kiosk table"

log "✅ kiosk-oss e2e green"
