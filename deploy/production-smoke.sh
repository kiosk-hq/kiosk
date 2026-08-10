#!/usr/bin/env bash
# Production-boot smoke for a representative demo — one per unique HTML surface.
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
# This boots a demo exactly like the deploy — RAILS_ENV=production
# (config.eager_load=true, config.assume_ssl=true) — and drives it through
# proxy+browser-shaped requests (X-Forwarded-Proto + a real https Origin) to
# catch all three classes at once. Any assertion miss exits non-zero.
#
# COVERAGE (K-462)
# ----------------
# One demo per UNIQUE human-facing HTML surface — booting all seven in prod is
# heavier CI for little marginal signal (the prod-only classes are per-surface,
# not per-app). Today two surfaces:
#
#   stylish  — Devise sign-in, roles, the manage page. Exercises the exact
#              surfaces the three original bugs touched (assume_ssl sign-in +
#              the governance-column render). The default when no arg is given.
#   prove    — the prove.my broker (kiosk-demo-prove): a NEW, distinct HTML
#              surface (the /verify human page) with a token-capability form
#              POST and NO login. Depends on no kiosk gem, seeds no signing key.
#              Verifies its four lib/ modules eager-load and /verify renders 200
#              (live form + clean not-recognised) rather than a 500.
#
# Usage:  production-smoke.sh [stylish|prove]     (default: stylish)
#
# Requires: Postgres reachable (PGHOST), a psql/pg client, and the demo's
# bundle installed. Env knobs: PORT, and the per-demo DB-role vars documented
# in each demo block below.
set -euo pipefail

DEMO="${1:-stylish}"

FAILURES=0
fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ok:   $*"; }

# ─────────────────────────────────────────────────────────────────────────────
# stylish: Devise sign-in + roles + manage page (the original three-bug surface)
# ─────────────────────────────────────────────────────────────────────────────
smoke_stylish() {
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

  # ── Production env the demo needs (mirrors deploy/env/stylish.env.example) ──
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

  SERVER_PID=""
  cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
    rm -f "$COOKIES" "$SERVER_LOG"
  }
  trap cleanup EXIT

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

  echo "── Assertion 5: forged cleartext identity bearer → 401 in production (K-539) ──"
  # The demos' StubIdp parses `agent:u-…:a-…:r-…` into an authenticated identity
  # at ANY role — a dev/test convenience. In production JwtOrStubIdp gates that
  # fallback behind Rails.env.local?, so a forged self-asserted bearer resolves to
  # NO identity and the wire raises 401. Before the K-539 fix this returned 200
  # (authenticated as a forged owner → cross-tenant read of the public `salons`
  # query). This is a production-config assertion, so it can catch the bug the
  # dev-mode CI + demo:redteam gates (which run RAILS_ENV=development, where the
  # stub is intentionally live) structurally cannot.
  FORGED_BEARER="agent:u-11111111-1111-4111-8111-111111111111:a-forged:r-owner"
  forged_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "${PROXY_HEADERS[@]}" -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${FORGED_BEARER}" \
    --data '{"name":"salons"}' \
    "${BASE}/kiosk/query")"
  if [ "$forged_code" = "401" ]; then
    pass "forged self-asserted bearer → 401 (cleartext stub unreachable in production)"
  else
    fail "forged bearer expected 401, got $forged_code (K-539: cleartext stub reachable in production — cross-tenant auth bypass!)"
  fi

  echo "── Assertion 6: forged human X-Staff-Session → 401 in production (K-555) ──"
  # stylish's StubUserIdp (the SSO/Okta stand-in) maps a self-asserted
  # `X-Staff-Session: <user_id>` header to a role-carrying HUMAN identity — so on
  # the wire it SELF-GRANTS that staff member's role. It is one arm of a composite
  # user_idp (StubUserIdp first, then real Devise). In production the initializer
  # drops the stub arm (Devise-only) AND StubUserIdp#verify returns nil unless
  # Rails.env.local?, so a forged X-Staff-Session naming the SEEDED OWNER resolves
  # to NO identity and POST /kiosk/auth/link raises 401 — no owner link can be
  # minted. Before the K-555 fix this returned 201 (a self-granted owner link →
  # the assistant redeeming it would INHERIT owner scope). This production-config
  # assertion catches the bug the dev-mode demo:roles/redteam gates (RAILS_ENV=
  # development, where the stub is intentionally live) structurally cannot.
  SEEDED_OWNER_ID="00000000-0000-0000-0000-0000000000a0"
  staff_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "${PROXY_HEADERS[@]}" -H "Content-Type: application/json" \
    -H "X-Staff-Session: ${SEEDED_OWNER_ID}" \
    "${BASE}/kiosk/auth/link")"
  if [ "$staff_code" = "401" ]; then
    pass "forged X-Staff-Session → 401 (role-carrying stub unreachable in production; no self-granted owner link)"
  else
    fail "forged X-Staff-Session expected 401, got $staff_code (K-555: role-carrying human stub reachable in production — staff-role self-grant!)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# prove: the prove.my broker (kiosk-demo-prove). A distinct HTML surface — the
# /verify human page — reached by an unguessable token capability, with a form
# POST but NO login. This app depends on NO kiosk gem and seeds NO signing key.
# The K-462 gap the stylish-only smoke did not cover.
# ─────────────────────────────────────────────────────────────────────────────
smoke_prove() {
  PORT="${PORT:-4140}"
  HOST="prove.smoke.local"
  BASE="http://127.0.0.1:${PORT}"
  ORIGIN="https://${HOST}"
  # The proxy shape Caddy presents (TLS-terminate → forward http + the headers).
  PROXY_HEADERS=(-H "X-Forwarded-Proto: https" -H "Host: ${HOST}")
  # The /verify form POST (assertion 5) deliberately OMITS X-Forwarded-Proto and
  # relies on config.assume_ssl ALONE to make request.base_url https — the same
  # K-439 reproduction as stylish's sign-in, applied to this app's ONLY form
  # POST. Rails 8.1's forgery_protection_origin_check runs even under
  # `protect_from_forgery with: :null_session`, so with assume_ssl off the https
  # Origin would mismatch a http base_url → 422; with it on the POST is accepted.
  POST_HEADERS=(-H "Host: ${HOST}")

  DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../kiosk-demo-prove" && pwd)"
  SERVER_LOG="$(mktemp -t kiosk-smoke-prove.XXXXXX)"
  cd "$DEMO_DIR"

  # ── Production env the broker needs. It has NO kiosk-gem dependency, so no
  # signing-key initializer, no PoW knobs — only SECRET_KEY_BASE + the DB role. ─
  export RAILS_ENV=production
  export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(ruby -e 'require "securerandom"; print SecureRandom.hex(64)')}"
  # database.yml (production) connects as this role (CI: postgres; local: login).
  export KIOSK_PROVE_DB_USER="${KIOSK_PROVE_DB_USER:-postgres}"
  export KIOSK_PROVE_DB_PASSWORD="${KIOSK_PROVE_DB_PASSWORD:-}"

  SERVER_PID=""
  cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
    rm -f "$SERVER_LOG"
  }
  trap cleanup EXIT

  echo "── Preparing production DB (drop/create/schema:load/seed) ──"
  DISABLE_DATABASE_ENVIRONMENT_CHECK=1 \
    bundle exec rails db:drop db:create db:schema:load db:seed >/dev/null

  # Seed ONE pending request so /verify?request=<id> renders the live yes/no form
  # (200) — the broker seeds no rows on its own (it is an issuer; rows appear
  # only at operator intake), so without this the live-form path is never
  # rendered under eager-load.
  echo "── Seeding one pending verification request ──"
  REQ="$(DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bundle exec rails runner '
    r = ProveRequest.create!(
      request_id:       "smoke-request-token-0001",
      operator_id:      "skooti",
      callback_url:     "https://127.0.0.1/kyc/callback",
      requested_claims: ["age_over_18", "licence_category:A"],
      subject_handle:   "smoke-agent-subject",
      nonce:            "smoke-nonce",
      status:           "pending",
      expires_at:       Time.current + 900,
    )
    print r.request_id
  ')"
  [ -n "$REQ" ] && pass "seeded pending request ${REQ}" || fail "could not seed a pending request"

  echo "── Booting prove.my broker in RAILS_ENV=production on ${BASE} (eager_load + assume_ssl) ──"
  bundle exec rails server -e production -b 127.0.0.1 -p "$PORT" >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!

  # Wait for readiness. If the process dies (a Zeitwerk eager-load crash on one
  # of the broker's four lib/ modules, K-422), surface the log and fail.
  ready=false
  for _ in $(seq 1 60); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "!! Server process exited during boot (eager-load crash?). Log:"
      cat "$SERVER_LOG"
      exit 1
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" "${BASE}/" || true)"
    if [ "$code" = "200" ]; then ready=true; break; fi
    sleep 1
  done
  if [ "$ready" != true ]; then
    echo "!! Server did not become ready. Log:"; cat "$SERVER_LOG"; exit 1
  fi
  echo "  server up"

  echo
  echo "── Assertion 1: GET / → 200 (eager-load smoke — all four lib/ modules load, K-422) ──"
  code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" "${BASE}/")"
  [ "$code" = "200" ] && pass "GET / → 200" || fail "GET / expected 200, got $code"

  echo "── Assertion 2: GET /verify?request=<seeded pending> → 200 live form (NOT 500) ──"
  body="$(curl -s "${PROXY_HEADERS[@]}" -H "Accept: text/html" "${BASE}/verify?request=${REQ}")"
  code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" -H "Accept: text/html" "${BASE}/verify?request=${REQ}")"
  if [ "$code" = "200" ] && printf '%s' "$body" | grep -qi "confirm these"; then
    pass "GET /verify (live) → 200 with the yes/no form"
  else
    fail "GET /verify (live) expected 200 + form, got $code"
  fi

  echo "── Assertion 3: GET /verify (no token) → 200 clean 'not recognised' (NOT 500) ──"
  body="$(curl -s "${PROXY_HEADERS[@]}" -H "Accept: text/html" "${BASE}/verify")"
  code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" -H "Accept: text/html" "${BASE}/verify")"
  if [ "$code" = "200" ] && printf '%s' "$body" | grep -qi "not recognised"; then
    pass "GET /verify (no token) → 200 'not recognised'"
  else
    fail "GET /verify (no token) expected 200 + 'not recognised', got $code"
  fi

  echo "── Assertion 4: GET /verify?request=bogus → 200 clean 'not recognised' (NOT 500) ──"
  code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" -H "Accept: text/html" "${BASE}/verify?request=this-token-does-not-exist")"
  [ "$code" = "200" ] && pass "GET /verify (unknown token) → 200" || fail "GET /verify (unknown token) expected 200, got $code"

  echo "── Assertion 5: POST /verify (decline) behind the proxy → 200, NOT 422 (assume_ssl/CSRF-Origin, K-439) ──"
  # Browser https Origin, assume_ssl-only (no X-Forwarded-Proto): the exact
  # K-439 condition. A regression of config.assume_ssl flips this to 422.
  post_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "${POST_HEADERS[@]}" -H "Origin: ${ORIGIN}" \
    --data-urlencode "request=${REQ}" \
    --data-urlencode "decision=decline" \
    "${BASE}/verify")"
  if [ "$post_code" = "200" ]; then
    pass "POST /verify → 200 (decided, not 422 forgery)"
  else
    fail "POST /verify expected 200, got $post_code (422 = CSRF-Origin rejection, K-439)"
  fi

  echo "── Assertion 6: GET /prove_key.pem → 200 (the ProveKey operators pin) ──"
  code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" "${BASE}/prove_key.pem")"
  [ "$code" = "200" ] && pass "GET /prove_key.pem → 200" || fail "GET /prove_key.pem expected 200, got $code"
}

case "$DEMO" in
  stylish) smoke_stylish ;;
  prove)   smoke_prove ;;
  *) echo "unknown demo '$DEMO' (expected: stylish | prove)"; exit 2 ;;
esac

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "OK production-boot smoke (${DEMO}): all assertions passed"
  exit 0
else
  echo "x production-boot smoke (${DEMO}): ${FAILURES} assertion(s) failed"
  echo "── server log ──"; [ -n "${SERVER_LOG:-}" ] && cat "$SERVER_LOG"
  exit 1
fi
