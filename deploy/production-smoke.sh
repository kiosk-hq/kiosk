#!/usr/bin/env bash
# Production-boot smoke for one representative demo (stylish).
#
# WHY THIS EXISTS
# ---------------
# Three real bugs (K-422, K-436, K-439) ALL shipped to the hosted demos and
# were invisible to dev-mode CI + the demo rake gates, because those boot the
# server in RAILS_ENV=development (lazy autoload, no proxy, no Origin check):
#
#   K-422  a lib/ helper's constant name mismatched Zeitwerk's expectation, so
#          `config.eager_load = true` (production only) raised on boot.
#   K-436  the «Manage assistants» page SELECTs governance columns a demo's
#          structure.sql lacked → HTTP 500 in production; demo:binding drives
#          the WIRE ceremony, never the HTML page render, so CI stayed green.
#   K-439  `config.assume_ssl` was off, so behind a TLS-terminating proxy the
#          Rails 8.1 CSRF Origin check rejected the browser's `Origin: https://`
#          POST as forgery → 422 + silent Devise sign-in failure.
#
# This boots stylish exactly like the deploy — RAILS_ENV=production
# (config.eager_load=true, config.assume_ssl=true) — and drives it through
# proxy+browser-shaped requests (X-Forwarded-Proto + a real https Origin) to
# catch all three classes at once. The sign-in assertion leans on assume_ssl
# alone (see SIGNIN_HEADERS) so it truly guards the K-439 fix. Any assertion
# miss exits non-zero.
#
# Stylish is the chosen representative: it exercises Devise sign-in, roles, and
# the manage page — the surfaces the three bugs touched.
#
# Requires: Postgres reachable (PGHOST), a psql/pg client, and the demo's
# bundle installed. Env knobs: PORT (default 4139), KIOSK_STYLISH_DB_USER
# (the DB role to connect as — `postgres` in CI, your login locally).
set -euo pipefail

PORT="${PORT:-4139}"
HOST="stylish.smoke.local"
BASE="http://127.0.0.1:${PORT}"
ORIGIN="https://${HOST}"
# Read/discovery requests carry the full proxy shape Caddy presents: it
# TLS-terminates and forwards HTTP with X-Forwarded-Proto: https + the real
# Host.
PROXY_HEADERS=(-H "X-Forwarded-Proto: https" -H "Host: ${HOST}")
# The Devise sign-in flow (assertion 4) deliberately OMITS X-Forwarded-Proto
# and relies on config.assume_ssl ALONE to make request.base_url https. That is
# the faithful K-439 reproduction: Rails already trusts X-Forwarded-Proto from a
# loopback proxy, so with that header present the Origin check passes EVEN when
# assume_ssl is off — masking the regression. Dropping it (browser Origin, but
# an ambiguous forwarded scheme) is the exact condition under which K-439 fired,
# so a regression of `config.assume_ssl = true` flips this assertion to 422.
SIGNIN_HEADERS=(-H "Host: ${HOST}")

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../kiosk-demo-stylish" && pwd)"
COOKIES="$(mktemp -t kiosk-smoke-cookies.XXXXXX)"
SERVER_LOG="$(mktemp -t kiosk-smoke-server.XXXXXX)"
cd "$DEMO_DIR"

# ── Production env the demo needs (mirrors deploy/env/stylish.env.example) ────
export RAILS_ENV=production
# A fixed dummy secret — this is an ephemeral smoke DB, not a real deploy.
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(ruby -e 'require "securerandom"; print SecureRandom.hex(64)')}"
# The production initializer does NOT self-provision a signing key (that only
# happens in dev/test), so supply an ephemeral one here or boot fails.
export KIOSK_SIGNING_KEY_B64="${KIOSK_SIGNING_KEY_B64:-$(ruby -e 'require "openssl"; require "base64"; print Base64.strict_encode64(OpenSSL::PKey::RSA.new(2048).to_pem)')}"
export KIOSK_ISSUER="${KIOSK_ISSUER:-$ORIGIN}"
# database.yml production reads these; connect as a role that can create/own the
# smoke DB (CI: postgres; local: your login role). No password under trust auth.
export KIOSK_STYLISH_DB_USER="${KIOSK_STYLISH_DB_USER:-postgres}"
export KIOSK_STYLISH_DB_PASSWORD="${KIOSK_STYLISH_DB_PASSWORD:-}"

FAILURES=0
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
  rm -f "$COOKIES" "$SERVER_LOG"
}
trap cleanup EXIT

fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ok:   $*"; }

echo "── Preparing production DB (drop/create/schema:load/seed) ──"
# db:prepare would migrate; the demos are schema_format=:sql and seed via the
# demo path, so mirror demo:setup: load structure.sql then seed. RAILS_ENV is
# production, so this builds kiosk_stylish_production. Rails guards destructive
# tasks against production DBs; this is a disposable smoke DB, so opt out of the
# guard for the prepare step only.
DISABLE_DATABASE_ENVIRONMENT_CHECK=1 \
  bundle exec rails db:drop db:create db:schema:load db:seed >/dev/null

echo "── Booting stylish in RAILS_ENV=production on ${BASE} (eager_load + assume_ssl) ──"
bundle exec rails server -e production -b 127.0.0.1 -p "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Wait for readiness. If the process dies (e.g. a Zeitwerk eager-load crash,
# K-422), surface the log and fail immediately.
ready=false
for _ in $(seq 1 60); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "!! Server process exited during boot (eager-load crash?). Log:"
    cat "$SERVER_LOG"
    exit 1
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" "${BASE}/.well-known/kiosk.json" || true)"
  if [ "$code" = "200" ]; then ready=true; break; fi
  sleep 1
done
if [ "$ready" != true ]; then
  echo "!! Server did not become ready. Log:"; cat "$SERVER_LOG"; exit 1
fi
echo "  server up"

echo
echo "── Assertion 1: GET / → 200 (catches eager-load Zeitwerk crashes, K-422) ──"
code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" "${BASE}/")"
[ "$code" = "200" ] && pass "GET / → 200" || fail "GET / expected 200, got $code"

echo "── Assertion 2: GET /.well-known/kiosk.json → 200 ──"
code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" "${BASE}/.well-known/kiosk.json")"
[ "$code" = "200" ] && pass "GET /.well-known/kiosk.json → 200" || fail "kiosk.json expected 200, got $code"

echo "── Assertion 3: GET /kiosk/auth/assistants unauthenticated → 302 to sign-in (K-436-class), NOT 500 ──"
resp="$(curl -s -D - -o /dev/null "${PROXY_HEADERS[@]}" -H "Accept: text/html" "${BASE}/kiosk/auth/assistants")"
code="$(printf '%s' "$resp" | awk 'NR==1{print $2}')"
loc="$(printf '%s' "$resp" | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')"
if [ "$code" = "302" ] && printf '%s' "$loc" | grep -q "/users/sign_in"; then
  pass "unauth manage page → 302 → $loc"
else
  fail "unauth manage page expected 302→/users/sign_in, got $code (location: ${loc:-none})"
fi

echo "── Assertion 4: real Devise sign-in behind the proxy (catches assume_ssl/CSRF-Origin, K-439) ──"
# (a) GET the sign-in form: grab the CSRF token + session cookie.
form="$(curl -s -c "$COOKIES" "${SIGNIN_HEADERS[@]}" -H "Accept: text/html" "${BASE}/users/sign_in")"
token="$(printf '%s' "$form" \
  | grep -o 'name="authenticity_token" value="[^"]*"' \
  | head -1 | sed 's/.*value="//; s/"$//')"
if [ -z "$token" ]; then
  fail "could not extract CSRF token from sign-in form"
else
  pass "got CSRF token + session cookie"
  # (b) POST credentials WITH the Origin header a browser sends but WITHOUT
  # X-Forwarded-Proto (see SIGNIN_HEADERS above). Under the K-439 bug
  # (assume_ssl off) Rails computes base_url=http:// and rejects this https
  # Origin as forgery → 422 + silent sign-in failure. With assume_ssl=true it
  # authenticates → 3xx redirect.
  signin_code="$(curl -s -o /dev/null -w '%{http_code}' \
    -c "$COOKIES" -b "$COOKIES" \
    "${SIGNIN_HEADERS[@]}" -H "Origin: ${ORIGIN}" \
    --data-urlencode "authenticity_token=${token}" \
    --data-urlencode "user[email]=owner@combette.example" \
    --data-urlencode "user[password]=combette-demo-password" \
    "${BASE}/users/sign_in")"
  if [ "$signin_code" = "302" ] || [ "$signin_code" = "303" ]; then
    pass "sign-in POST → $signin_code (redirect, not 422 forgery)"
  else
    fail "sign-in POST expected 302/303 redirect, got $signin_code (422 = CSRF-Origin rejection, K-439)"
  fi
  # (c) With the authenticated session cookie, the manage page now renders 200.
  authed_code="$(curl -s -o /dev/null -w '%{http_code}' \
    -b "$COOKIES" "${SIGNIN_HEADERS[@]}" -H "Accept: text/html" \
    "${BASE}/kiosk/auth/assistants")"
  [ "$authed_code" = "200" ] \
    && pass "signed-in manage page → 200" \
    || fail "signed-in manage page expected 200, got $authed_code"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "OK production-boot smoke: all assertions passed"
  exit 0
else
  echo "x production-boot smoke: ${FAILURES} assertion(s) failed"
  echo "── server log ──"; cat "$SERVER_LOG"
  exit 1
fi
