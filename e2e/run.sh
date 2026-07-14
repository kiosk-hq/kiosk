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
#   - Ruby 4.0+ with bundler
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
  psql -d postgres -tAc "DROP DATABASE IF EXISTS $DB_NAME" >/dev/null 2>&1 || true
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

pg_isready -q || fail "postgres not accepting connections (run: brew services start postgresql)"

[ -d "$KIOSK_OSS/kiosk-core" ] || fail "KIOSK_OSS=$KIOSK_OSS missing kiosk-core (set KIOSK_OSS to the reference monorepo root)"

ok "all prerequisites present"

# Pre-create app_role so Kiosk.configure app_role= / system_role= reference
# a real PG role. NOLOGIN + grant to current user is harmless forward-compat:
# Path C uses app-layer isolation (named queries), not RLS. Role separation
# lands in a follow-up — see e2e/README.md.
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
rails new "$APP_NAME" --skip-bundle -d postgresql --skip-test --api --skip-git \
  >/dev/null 2>&1
cd "$APP_NAME"
ok "$APP_NAME generated"

# ─── Gemfile patch (path overrides) ─────────────────────────────────────

cat >> Gemfile <<RUBY

# Kiosk OSS gems via path overrides (sibling clone of kiosk-hq/kiosk).
# kiosk-rls is REQUIRED even though this fixture does not use RLS: it is the
# only source of Configuration#system_role=, which initializer_kiosk.rb sets.
# Dropping it makes the initializer raise NoMethodError at boot.
gem "kiosk-all",    path: "$KIOSK_OSS/kiosk-all"
gem "kiosk-core",   path: "$KIOSK_OSS/kiosk-core"
gem "kiosk-rls",    path: "$KIOSK_OSS/kiosk-rls"
gem "kiosk-server", path: "$KIOSK_OSS/kiosk-server"
RUBY

log "bundle install (this can take a moment on a cold cache)"
bundle install --quiet
ok "bundle complete"

# ─── DB config ──────────────────────────────────────────────────────────

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

# 2) Generator-produced migrations.
bundle exec rails g kiosk:install --user-id-type=uuid >/dev/null

# 3) Demo schema (salons + appointments + RLS). Timestamp = now + 60s —
# enough to run after the kiosk:install migrations (which use Time.now)
# while staying inside Rails's «migration timestamp ≤ now + 1day» check.
ts3=$(ruby -e "puts (Time.now + 60).utc.strftime('%Y%m%d%H%M%S')")
cp "$FIXTURES/create_salons_and_appointments.rb" \
   "db/migrate/${ts3}_create_salons_and_appointments.rb"

# 4) Models, seeds, stub IdP, initializer, routes.
cp "$FIXTURES/user.rb"               app/models/user.rb
cp "$FIXTURES/salon.rb"              app/models/salon.rb
cp "$FIXTURES/appointment.rb"        app/models/appointment.rb
cp "$FIXTURES/seeds.rb"              db/seeds.rb
mkdir -p lib
cp "$FIXTURES/stub_idp.rb"           lib/stub_idp.rb
cp "$FIXTURES/jwt_or_stub_idp.rb"    lib/jwt_or_stub_idp.rb
cp "$FIXTURES/stub_psp.rb"           lib/stub_psp.rb
cp "$FIXTURES/initializer_kiosk.rb"  config/initializers/kiosk.rb
cp "$FIXTURES/routes.rb"             config/routes.rb

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

# ─── DB-level dedupe of live agent keys (K-043) ─────────────────────────
# Prove the partial UNIQUE index (public_key WHERE revoked_at IS NULL)
# rejects a SECOND live agent row for one key at the DB level — not via a
# TOCTOU SELECT-then-INSERT. A revoked row for the same key is allowed.
log "assert DB-level uniqueness on kiosk.agents.public_key (live rows)"
K043_KEY="k043-dup-$$"
psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -qtA >/dev/null 2>&1 <<SQL || fail "K-043 setup insert failed"
  INSERT INTO users (id, created_at, updated_at) VALUES (gen_random_uuid(), now(), now());
  INSERT INTO kiosk.agents (user_id, allowed_roles, public_key)
    SELECT id, ARRAY['customer']::text[], '$K043_KEY' FROM users LIMIT 1;
SQL
# Second LIVE insert of the same key must be REJECTED by the unique index.
if psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -qtA >/dev/null 2>&1 <<SQL
  INSERT INTO kiosk.agents (user_id, allowed_roles, public_key)
    SELECT id, ARRAY['customer']::text[], '$K043_KEY' FROM users LIMIT 1;
SQL
then
  fail "K-043: a SECOND live agent row with the same public_key was accepted (unique index missing)"
fi
# A revoked row for the same key IS allowed (partial index skips revoked rows).
psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -qtA >/dev/null 2>&1 <<SQL || fail "K-043: revoked-key re-insert wrongly rejected"
  INSERT INTO kiosk.agents (user_id, allowed_roles, public_key, revoked_at)
    SELECT id, ARRAY['customer']::text[], '$K043_KEY', now() FROM users LIMIT 1;
SQL
psql -d "$DB_NAME" -qtA >/dev/null 2>&1 <<SQL || true
  DELETE FROM kiosk.agents WHERE public_key = '$K043_KEY';
SQL
ok "K-043: live-key uniqueness enforced at the DB; revoked key may re-register"

# ─── signing key for JWKS (kiosk-pop JWTs) ──────────────────────────────
log "generate signing key for JWKS (kiosk-pop JWTs)"
SIGNING_KEY_PEM=$(openssl genrsa 2048 2>/dev/null)
export KIOSK_SIGNING_KEY_B64=$(echo "$SIGNING_KEY_PEM" | base64)
ok "signing key generated"

# ─── start server ───────────────────────────────────────────────────────

log "start rails server on port $SERVER_PORT"
export KIOSK_ISSUER="http://127.0.0.1:$SERVER_PORT"
bundle exec rails s -p "$SERVER_PORT" -b 127.0.0.1 -e development \
  > /tmp/kiosk-e2e-server.log 2>&1 &
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
  tail -50 /tmp/kiosk-e2e-server.log
  fail "server did not become ready on http://127.0.0.1:$SERVER_PORT (see log above)"
}
ok "server up on http://127.0.0.1:$SERVER_PORT"

# ─── run the assistant ──────────────────────────────────────────────────

log "run mock AI-assistant test suite"
if ! SERVER_URL="http://127.0.0.1:$SERVER_PORT" \
       APP_DIR="$PWD" \
       FIXTURES="$FIXTURES" \
       DB_NAME="$DB_NAME" \
       KIOSK_ISSUER="$KIOSK_ISSUER" \
       bash "$KIOSK_OSS/e2e/assistant.sh"; then
  log "assistant failed — last 80 lines of server log:"
  tail -80 /tmp/kiosk-e2e-server.log
  exit 1
fi

ok "all assertions passed"
log "✅ kiosk-oss e2e green"
