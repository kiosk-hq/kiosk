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
# It also drives ASSISTANT-shaped requests at the human surfaces (K-534), for
# the same reason: the bodyless-error class (K-459, K-532, K-533) exists ONLY
# in production, where ShowExceptions/PublicExceptions replace the debug page,
# so no dev-mode suite or demo rake gate can see a regression of it.
#
# COVERAGE (K-462, widened by K-1085)
# ----------------------------------
# One demo per UNIQUE human-facing HTML surface, PLUS any app whose HTML is
# rendered from a HAND-WRITTEN SQL projection. Booting all seven in prod would
# be heavier CI for little marginal signal; booting only two was measurably too
# few. Today three:
#
#   stylish  — Devise sign-in, roles, the manage page. Exercises the exact
#              surfaces the three original bugs touched (assume_ssl sign-in +
#              the governance-column render). The default when no arg is given.
#   prove    — the KYC broker (kiosk-demo-prove): a NEW, distinct HTML
#              surface (the /verify human page) with a token-capability form
#              POST and NO login. Depends on no kiosk gem, seeds no signing key.
#              Verifies its four lib/ modules eager-load and /verify renders 200
#              (live form + clean not-recognised) rather than a 500.
#   tudu     — the housemate board (`/shared`) and the fleet's ONLY open
#              sign-up. See below for why it is here.
#
# WHY THE ROSTER GREW, AND THE PREMISE IT COST (K-1085)
# ----------------------------------------------------
# The rule above used to read «one demo per unique human-facing HTML surface»
# alone, resting on «the prod-only classes are per-surface, not per-app». That
# premise has a measured counterexample and it is the surface that broke.
#
# It holds for THREE of the four classes this script gates — a Zeitwerk
# eager-load crash (K-422), the assume_ssl/CSRF-Origin rejection (K-439) and the
# bodyless-error class (K-459/K-532/K-533/K-534) are all properties of a SURFACE
# SHAPE, and one demo per shape really does cover them. It does NOT hold for the
# fourth, which is the class this script was built for: K-436, «the code SELECTs
# something this app's database has not got». That one is per-APP by
# construction, because the SQL is per-app — and tudu is the fleet's only HTML
# page rendered from a hand-written `exec_query`
# (`kiosk-demo-tudu/app/controllers/lists_controller.rb#housemate_board`: a
# four-table join over memberships/lists/memberships/users with an aliased
# `owner_u.display_name`). Not one column of that projection is validated by a
# model, a scope or a structure.sql-derived attribute set. tudu also carries a
# genuinely unique surface on the first three classes: it is the ONLY demo in
# the fleet offering open Devise REGISTRATION, with its own
# Users::RegistrationsController — a second form POST under the K-439 condition,
# in a controller no other demo eager-loads.
#
# WHAT ADDING TUDU DOES NOT BUY, stated here so nobody re-derives it or mistakes
# this for the fix to K-1074: IT WOULD NOT HAVE CAUGHT K-1074. This script builds
# its throwaway `_smoke` database with `db:schema:load` out of the tracked
# `structure.sql` (see the prepare step below) — from zero, where
# `display_name` is present — so a column that is in the TREE and missing on the
# BOX is invisible to it, in tudu exactly as in every other demo. That escape is
# closed before the deploy by `bin/check-migration-replay` (K-1082) and after it
# by the live post-deploy probe K-1074/K-1075 commission. Three gates, three
# different halves; K-436 → K-462 already made the mistake of treating one as a
# substitute for another, which is how the class came back.
#
# ─────────────────────────────────────────────────────────────────────────────
# THIS IS NOT A SCRIPT YOU RUN AGAINST A DEPLOYMENT (K-594)
# ─────────────────────────────────────────────────────────────────────────────
# "production" in the name is the Rails ENVIRONMENT this smoke boots, not a
# machine. The script CREATES AND DROPS a database, so it may only ever touch a
# throwaway one. Three controls enforce that — none of them is a comment:
#
#   1. THROWAWAY NAME. The target is PINNED to `kiosk_<app>_smoke`. A deployment
#      uses `kiosk_<app>_production` (deploy/postgres-init.sql, deploy/env/*),
#      so no name a deployment uses is ever targeted at all. Pinned rather than
#      inherited (K-583) so an ambient `KIOSK_<APP>_DB` cannot redirect it.
#   2. NAME ASSERTION. Every destructive command goes through drop_smoke_db(),
#      which REFUSES any database whose name does not end in `_smoke`. An edit
#      that reintroduces a deploy name fails loudly instead of running.
#   3. FAIL-CLOSED HOST/INTENT GATE. require_disposable_host() aborts outright
#      when the box carries deploy markers (`/srv/kiosk`, `/etc/kiosk-demo`, an
#      installed `kiosk-demo@.service`) — nothing overrides that — and otherwise
#      demands that the caller STATE disposability: `CI` set (the CI workflow
#      also passes the variable explicitly), or `KIOSK_SMOKE_I_AM_DISPOSABLE=1`
#      by hand. A bare run on an unmarked box refuses rather than guessing.
#
# `DISABLE_DATABASE_ENVIRONMENT_CHECK` is NOT set anywhere in this script, and
# must not be reintroduced. Rails' protected-environments guard stays ARMED: the
# drop is a psql `DROP DATABASE` against an asserted `_smoke` name, and the
# freshly created database carries no stored environment, which the guard passes
# on its own. Point this script at a real deploy database and `db:schema:load`
# refuses — the platform control is back to being a control (K-594).
#
# Usage:  [KIOSK_SMOKE_I_AM_DISPOSABLE=1] production-smoke.sh [stylish|prove]
#         (default demo: stylish)
#
# Requires: Postgres reachable (PGHOST), a psql/pg client, and the demo's
# bundle installed. Env knobs: PORT, and the per-demo DB-role vars documented
# in each demo block below.
set -euo pipefail

DEMO="${1:-stylish}"
case "$DEMO" in
  stylish | prove | tudu) ;;
  *) echo "unknown demo '$DEMO' (expected: stylish | prove | tudu)"; exit 2 ;;
esac

FAILURES=0
fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ok:   $*"; }

# ── Safety controls (K-594) ─────────────────────────────────────────────────
# Control 3: refuse to run anywhere the dropped database might not be throwaway.
require_disposable_host() {
  local marker
  for marker in /srv/kiosk /etc/kiosk-demo /etc/systemd/system/kiosk-demo@.service; do
    if [ -e "$marker" ]; then
      {
        echo "!! REFUSING TO RUN: this box looks like a Kiosk deploy host — ${marker} exists."
        echo "!! production-smoke.sh drops and rebuilds a database. It is a CI/laptop gate,"
        echo "!! never something to run on a machine that serves the hosted demos."
        echo "!! There is no override for this check (K-594)."
      } >&2
      exit 3
    fi
  done

  if [ -z "${CI:-}" ] && [ "${KIOSK_SMOKE_I_AM_DISPOSABLE:-}" != "1" ]; then
    {
      echo "!! REFUSING TO RUN: nothing here states that the target database is disposable."
      echo "!! production-smoke.sh DROPS kiosk_${DEMO}_smoke and rebuilds it from scratch."
      echo "!! Run it only where losing that database is fine:"
      echo "!!     KIOSK_SMOKE_I_AM_DISPOSABLE=1 deploy/production-smoke.sh ${DEMO}"
      echo "!! CI sets CI=true and passes the same variable explicitly (K-594)."
    } >&2
    exit 3
  fi
}

# Control 2: the only destructive statement in the script, and it refuses any
# database that is not a `_smoke` one. Deliberately psql and not `rails db:drop`
# — that task under RAILS_ENV=production would need
# DISABLE_DATABASE_ENVIRONMENT_CHECK, and disarming the platform guard is the
# defect K-594 filed.
drop_smoke_db() {
  local db="$1" user="$2" pw="$3"
  case "$db" in
    *_smoke) ;;
    *)
      echo "!! REFUSING: '${db}' is not a *_smoke database — this script only ever drops throwaway ones (K-594)." >&2
      exit 3
      ;;
  esac
  if [ -n "$pw" ]; then
    PGPASSWORD="$pw" psql -v ON_ERROR_STOP=1 -qtAX -U "$user" -d postgres \
      -c "DROP DATABASE IF EXISTS \"${db}\" WITH (FORCE);" >/dev/null
  else
    psql -v ON_ERROR_STOP=1 -qtAX -U "$user" -d postgres \
      -c "DROP DATABASE IF EXISTS \"${db}\" WITH (FORCE);" >/dev/null
  fi
}

require_disposable_host

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
  # K-541 made the PoW HMAC key mandatory outside development/test — the app
  # refuses to boot without it, so the smoke must supply an ephemeral one here
  # exactly as it does the signing key.
  export KIOSK_POW_SECRET="${KIOSK_POW_SECRET:-$(ruby -e 'require "securerandom"; print SecureRandom.hex(32)')}"
  # database.yml production reads these; connect as a role that can create/own the
  # smoke DB (CI: postgres; local: your login role). No password under trust auth.
  export KIOSK_STYLISH_DB_USER="${KIOSK_STYLISH_DB_USER:-postgres}"
  export KIOSK_STYLISH_DB_PASSWORD="${KIOSK_STYLISH_DB_PASSWORD:-}"
  # PINNED, not inherited: the prepare step below DROPS this database, so it must
  # never follow an ambient KIOSK_STYLISH_DB (K-583) and must never be the deploy
  # name `kiosk_stylish_production` (K-594). `_smoke` is a name no deployment
  # provisions, and drop_smoke_db refuses anything else.
  export KIOSK_STYLISH_DB="kiosk_stylish_smoke"

  SERVER_PID=""
  cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
    rm -f "$COOKIES" "$SERVER_LOG"
  }
  trap cleanup EXIT

  echo "── Preparing the throwaway smoke DB ${KIOSK_STYLISH_DB} (drop/create/schema:load/seed) ──"
  # db:prepare would migrate; the demos are schema_format=:sql and seed via the
  # demo path, so mirror demo:setup: load structure.sql then seed. RAILS_ENV is
  # production — the whole point — but the DATABASE is the throwaway `_smoke` one,
  # dropped by drop_smoke_db (which refuses any non-`_smoke` name). Rails' own
  # protected-environments guard is left ARMED: the recreated database has no
  # stored environment, so db:schema:load passes it without being disabled.
  drop_smoke_db "$KIOSK_STYLISH_DB" "$KIOSK_STYLISH_DB_USER" "$KIOSK_STYLISH_DB_PASSWORD"
  bundle exec rails db:create db:schema:load db:seed >/dev/null

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

  echo "── Assertion 5: forged cleartext identity bearer → 401 (K-539) ──"
  # A `agent:u-…:a-…:r-…` bearer names a user, an agent and a ROLE, and the demos
  # once shipped a parser that believed all three — a dev/test convenience gated
  # behind Rails.env.local?. Before the K-539 fix this probe returned 200
  # (authenticated as a forged owner → cross-tenant read of the public `salons`
  # query), and the gate is what made it 401 here.
  #
  # T-104 deleted the parser outright: assistants authenticate with the kiosk-pop
  # JWT the engine minted, verified by the engine's own DefaultAgentIdp, and no
  # demo overrides `c.agent_idp` at all. The assertion is kept — and it is now
  # stronger than a gate on an env check, because the arm it probes for does not
  # exist in ANY environment. The dev-mode CI + demo:redteam gates assert the
  # same refusal now, which they structurally could not while the stub was
  # intentionally live under RAILS_ENV=development.
  # Protocol 0.4: a query is `GET <endpoint>/<query-name>`. Identity resolves
  # BEFORE the verb is looked up, so this probe is a 401 whether or not the
  # name exists — which is exactly the property being asserted, and also why an
  # unauthenticated caller cannot enumerate the catalog one path at a time.
  FORGED_BEARER="agent:u-11111111-1111-4111-8111-111111111111:a-forged:r-owner"
  forged_code="$(curl -s -o /dev/null -w '%{http_code}' \
    "${PROXY_HEADERS[@]}" \
    -H "Authorization: Bearer ${FORGED_BEARER}" \
    "${BASE}/kiosk/salons")"
  if [ "$forged_code" = "401" ]; then
    pass "forged self-asserted bearer → 401 (no cleartext parser exists to reach)"
  else
    fail "forged bearer expected 401, got $forged_code (K-539: something is parsing self-asserted bearers — cross-tenant auth bypass!)"
  fi

  echo "── Assertion 6: forged human X-Staff-Session → 401 in production (K-555) ──"
  # stylish USED to map a self-asserted `X-Staff-Session: <user_id>` header to a
  # role-carrying HUMAN identity — the salon's SSO/Okta stand-in, one arm of a
  # composite user_idp — so on the wire that header SELF-GRANTED a staff role
  # (before K-555 this returned 201: a self-granted owner link, and the assistant
  # redeeming it would INHERIT owner scope).
  #
  # T-066 deleted the stand-in outright: `c.user_idp` is the Devise adapter alone,
  # in every environment, and nothing reads that header any more. The assertion is
  # kept — and it is now stronger than a gate on an env check, because the arm it
  # guarded does not exist to be re-enabled. It stays here rather than moving into
  # the redteam battery because this is the PRODUCTION box: the one place that can
  # say the deployed config, not a local one, refuses.
  SEEDED_OWNER_ID="00000000-0000-0000-0000-0000000000a0"
  staff_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "${PROXY_HEADERS[@]}" -H "Content-Type: application/json" \
    -H "X-Staff-Session: ${SEEDED_OWNER_ID}" \
    "${BASE}/kiosk/auth/link")"
  if [ "$staff_code" = "401" ]; then
    pass "forged X-Staff-Session → 401 (no role-carrying stand-in exists; no self-granted owner link)"
  else
    fail "forged X-Staff-Session expected 401, got $staff_code (K-555: a role-carrying human stand-in is reachable in production — staff-role self-grant!)"
  fi

  echo "── Assertion 7: JSON POST at the human sign-in form → 422 + Kiosk error envelope (K-459/K-534) ──"
  # The DEMO half of the K-459 agent-signpost had no gate: the engine half is
  # pinned by rspec, but each demo's own ApplicationController rescue was only
  # ever exercised by a human-shaped POST here (assertion 4). A regression puts
  # this back to a bodyless 422 — the exact unactionable answer K-459 removed.
  # Production is the only place it reproduces (dev renders the debug page).
  signpost="$(curl -s -X POST "${PROXY_HEADERS[@]}" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    --data '{"user":{"email":"probe@example.com","password":"probe"}}' \
    "${BASE}/users/sign_in")"
  signpost_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${PROXY_HEADERS[@]}" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    --data '{"user":{"email":"probe@example.com","password":"probe"}}' \
    "${BASE}/users/sign_in")"
  if [ "$signpost_code" = "422" ] && printf '%s' "$signpost" | grep -q "invalid_authenticity_token"; then
    pass "JSON sign-in POST → 422 + invalid_authenticity_token envelope"
  else
    fail "JSON sign-in POST expected 422 + invalid_authenticity_token envelope, got $signpost_code / '$(printf '%s' "$signpost" | head -c 120)' (K-459 signpost regressed to a bodyless error)"
  fi

  echo "── Assertion 8: JSON DELETE /users/sign_out → 401 + Kiosk error envelope (K-533) ──"
  # Devise answers a session-less sign-out with `head :unauthorized`: 401,
  # Content-Type: application/json, ZERO bytes — a content type promising JSON
  # with nothing to parse. Users::SessionsController hands JSON-shaped callers
  # the envelope instead; navigational and 204 paths stay Devise's.
  signout="$(curl -s -X DELETE "${PROXY_HEADERS[@]}" -H "Accept: application/json" "${BASE}/users/sign_out")"
  signout_code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "${PROXY_HEADERS[@]}" \
    -H "Accept: application/json" "${BASE}/users/sign_out")"
  if [ "$signout_code" = "401" ] && printf '%s' "$signout" | grep -q "not_signed_in"; then
    pass "JSON sign-out DELETE → 401 + not_signed_in envelope (not a bodyless 401)"
  else
    fail "JSON sign-out DELETE expected 401 + not_signed_in envelope, got $signout_code / '$(printf '%s' "$signout" | head -c 120)' (K-533)"
  fi

  echo "── Assertion 9: unknown path → 404 with a BODY (public/404.html, K-532) ──"
  # Without public/404.html, PublicExceptions falls through and ShowExceptions
  # returns text/html + Content-Length: 0 for every unhandled 404 — the answer
  # an assistant guessing web-app paths (POST /bookings) hits most often.
  notfound_len="$(curl -s -o /dev/null -w '%{size_download}' "${PROXY_HEADERS[@]}" \
    -H "Accept: text/html" "${BASE}/this-path-does-not-exist")"
  notfound_code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" \
    -H "Accept: text/html" "${BASE}/this-path-does-not-exist")"
  if [ "$notfound_code" = "404" ] && [ "$notfound_len" -gt 0 ]; then
    pass "unknown path → 404 with ${notfound_len} bytes of body"
  else
    fail "unknown path expected 404 with a non-empty body, got $notfound_code / ${notfound_len} bytes (K-532: no public/404.html → bodyless error)"
  fi

  echo "── Assertion 10: GET /robots.txt and /favicon.ico → 200 statics (T-048) ──"
  # Caddy proxies EVERYTHING to Puma (no file_server in deploy/Caddyfile), so
  # these serve only if ActionDispatch::Static answers them ahead of routing —
  # Rails 8 defaults config.public_file_server.enabled to true and the demos'
  # production.rb leaves it on (it only sets headers). Before T-048 the files
  # did not exist, so every crawler hit raised ActionController::RoutingError
  # into the production journal; this pins the 200s so that noise cannot return.
  robots_code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" "${BASE}/robots.txt")"
  favicon_code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" "${BASE}/favicon.ico")"
  if [ "$robots_code" = "200" ] && [ "$favicon_code" = "200" ]; then
    pass "GET /robots.txt → 200, GET /favicon.ico → 200"
  else
    fail "statics expected 200/200, got robots.txt=$robots_code favicon.ico=$favicon_code (T-048: a missing public/ static puts RoutingError noise back in the journal)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# prove: the KYC broker (kiosk-demo-prove). A distinct HTML surface — the
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
  # kiosk signing-key initializer, no PoW knobs — SECRET_KEY_BASE, the DB role,
  # and its OWN RSA signing key (the ProveKey). ─
  export RAILS_ENV=production
  export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(ruby -e 'require "securerandom"; print SecureRandom.hex(64)')}"
  # The broker refuses to boot in production without PROVE_KEY_PEM (K-673), and
  # the env file validates that it parses as an RSA PRIVATE key — so generate a
  # throwaway keypair (nothing pins it: assertion 6 only asserts /prove_key.pem
  # serves ITS public half).
  export PROVE_KEY_PEM="${PROVE_KEY_PEM:-$(ruby -e 'require "openssl"; print OpenSSL::PKey::RSA.new(2048).to_pem')}"
  # database.yml (production) connects as this role (CI: postgres; local: login).
  export KIOSK_PROVE_DB_USER="${KIOSK_PROVE_DB_USER:-postgres}"
  export KIOSK_PROVE_DB_PASSWORD="${KIOSK_PROVE_DB_PASSWORD:-}"
  # PINNED, not inherited, and a throwaway `_smoke` name rather than the deploy
  # `kiosk_prove_production` — see the stylish smoke above (K-583/K-594).
  export KIOSK_PROVE_DB="kiosk_prove_smoke"

  SERVER_PID=""
  cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
    rm -f "$SERVER_LOG"
  }
  trap cleanup EXIT

  echo "── Preparing the throwaway smoke DB ${KIOSK_PROVE_DB} (drop/create/schema:load/seed) ──"
  drop_smoke_db "$KIOSK_PROVE_DB" "$KIOSK_PROVE_DB_USER" "$KIOSK_PROVE_DB_PASSWORD"
  bundle exec rails db:create db:schema:load db:seed >/dev/null

  # Seed ONE pending request so /verify?request=<id> renders the live yes/no form
  # (200) — the broker seeds no rows on its own (it is an issuer; rows appear
  # only at operator intake), so without this the live-form path is never
  # rendered under eager-load.
  echo "── Seeding one pending verification request ──"
  REQ="$(bundle exec rails runner '
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

  echo "── Booting KYC broker in RAILS_ENV=production on ${BASE} (eager_load + assume_ssl) ──"
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

  echo "── Assertion 7: unknown path → 404 with a BODY (public/404.html, K-532) ──"
  # Same class as the stylish assertion: with no public/404.html, PublicExceptions
  # falls through and every unhandled 404 answers text/html + Content-Length: 0.
  # Guessed paths are the norm here — the only real URL carries a random token.
  notfound_len="$(curl -s -o /dev/null -w '%{size_download}' "${PROXY_HEADERS[@]}" \
    -H "Accept: text/html" "${BASE}/this-path-does-not-exist")"
  notfound_code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" \
    -H "Accept: text/html" "${BASE}/this-path-does-not-exist")"
  if [ "$notfound_code" = "404" ] && [ "$notfound_len" -gt 0 ]; then
    pass "unknown path → 404 with ${notfound_len} bytes of body"
  else
    fail "unknown path expected 404 with a non-empty body, got $notfound_code / ${notfound_len} bytes (K-532: no public/404.html → bodyless error)"
  fi

  echo "── Assertion 8: GET /robots.txt and /favicon.ico → 200 statics (T-048) ──"
  # Same mechanism as the stylish assertion: Caddy proxies everything to Puma,
  # so only ActionDispatch::Static (on by default in Rails 8 production) stands
  # between a crawler and a logged RoutingError. The broker shares the eight-app
  # robots.txt policy and the one Kiosk favicon.
  robots_code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" "${BASE}/robots.txt")"
  favicon_code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" "${BASE}/favicon.ico")"
  if [ "$robots_code" = "200" ] && [ "$favicon_code" = "200" ]; then
    pass "GET /robots.txt → 200, GET /favicon.ico → 200"
  else
    fail "statics expected 200/200, got robots.txt=$robots_code favicon.ico=$favicon_code (T-048: a missing public/ static puts RoutingError noise back in the journal)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# tudu: the housemate board + the fleet's only open sign-up (K-1085). The third
# surface, and the reason is in the COVERAGE header: `/shared` is the only HTML
# page in the fleet rendered from a hand-written SQL projection, and
# `/users/sign_up` is the only open Devise registration. Both are among the four
# tudu pages that answered HTTP 500 on the live box (K-1074).
# ─────────────────────────────────────────────────────────────────────────────
smoke_tudu() {
  PORT="${PORT:-4141}"
  HOST="tudu.smoke.local"
  BASE="http://127.0.0.1:${PORT}"
  ORIGIN="https://${HOST}"
  PROXY_HEADERS=(-H "X-Forwarded-Proto: https" -H "Host: ${HOST}")
  # Same K-439 reproduction as stylish's sign-in: browser https Origin, and
  # assume_ssl ALONE to make request.base_url https. Used for BOTH of tudu's
  # form POSTs — sign-in and the open sign-up no other demo has.
  SIGNIN_HEADERS=(-H "Host: ${HOST}")

  DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../kiosk-demo-tudu" && pwd)"
  COOKIES="$(mktemp -t kiosk-smoke-tudu-cookies.XXXXXX)"
  SERVER_LOG="$(mktemp -t kiosk-smoke-tudu.XXXXXX)"
  cd "$DEMO_DIR"

  # ── Production env the demo needs (mirrors deploy/env/tudu.env.example) ──
  export RAILS_ENV=production
  export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(ruby -e 'require "securerandom"; print SecureRandom.hex(64)')}"
  # The production initializer self-provisions neither the signing key nor the
  # K-541 PoW secret and refuses to boot without them (same as stylish).
  export KIOSK_SIGNING_KEY_B64="${KIOSK_SIGNING_KEY_B64:-$(ruby -e 'require "openssl"; require "base64"; print Base64.strict_encode64(OpenSSL::PKey::RSA.new(2048).to_pem)')}"
  export KIOSK_ISSUER="${KIOSK_ISSUER:-$ORIGIN}"
  export KIOSK_POW_SECRET="${KIOSK_POW_SECRET:-$(ruby -e 'require "securerandom"; print SecureRandom.hex(32)')}"
  export KIOSK_TUDU_DB_USER="${KIOSK_TUDU_DB_USER:-postgres}"
  export KIOSK_TUDU_DB_PASSWORD="${KIOSK_TUDU_DB_PASSWORD:-}"
  # PINNED, not inherited, and a throwaway `_smoke` name rather than the deploy
  # `kiosk_tudu_production` — see the stylish smoke above (K-583/K-594).
  export KIOSK_TUDU_DB="kiosk_tudu_smoke"

  SERVER_PID=""
  cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
    rm -f "$COOKIES" "$SERVER_LOG"
  }
  trap cleanup EXIT

  echo "── Preparing the throwaway smoke DB ${KIOSK_TUDU_DB} (drop/create/schema:load/seed) ──"
  # From zero out of structure.sql, exactly as the two smokes above — which is
  # also precisely what this smoke CANNOT see (K-1074's delivery gap); see the
  # COVERAGE header.
  drop_smoke_db "$KIOSK_TUDU_DB" "$KIOSK_TUDU_DB_USER" "$KIOSK_TUDU_DB_PASSWORD"
  bundle exec rails db:create db:schema:load db:seed >/dev/null

  echo "── Booting tudu in RAILS_ENV=production on ${BASE} (eager_load + assume_ssl) ──"
  bundle exec rails server -e production -b 127.0.0.1 -p "$PORT" >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!

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
  echo "── Assertion 1: GET / → 200 (eager-load, and the signed-out root renders the board) ──"
  code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" -H "Accept: text/html" "${BASE}/")"
  [ "$code" = "200" ] && pass "GET / → 200" || fail "GET / expected 200, got $code"

  echo "── Assertion 2: GET /shared → 200 AND the hand-written projection RESOLVED (K-436 class, K-1085) ──"
  # The assertion that matters is not the status: it is that the four-table join
  # in ListsController#housemate_board returned the seeded row WITH the owner's
  # display name. `shared by Alice` can only be printed if `owner_u.display_name`
  # resolved — a column no model, scope or structure.sql-derived attribute set
  # covers, in the only page in the fleet whose SQL is written by hand. A 200
  # alone would also pass on the empty-board branch, which is the failure mode
  # this assertion exists to refuse.
  shared_body="$(curl -s "${PROXY_HEADERS[@]}" -H "Accept: text/html" "${BASE}/shared")"
  shared_code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" -H "Accept: text/html" "${BASE}/shared")"
  if [ "$shared_code" = "200" ] && printf '%s' "$shared_body" | grep -q "Flat 3B" \
     && printf '%s' "$shared_body" | grep -q "shared by Alice"; then
    pass "GET /shared → 200, board shows the seeded list attributed to its owner"
  else
    fail "GET /shared expected 200 with 'Flat 3B' + 'shared by Alice', got $shared_code (K-1085: the hand-written housemate_board projection did not resolve)"
  fi

  echo "── Assertion 3: GET /users/sign_up → 200 (the fleet's only open registration) ──"
  code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" -H "Accept: text/html" "${BASE}/users/sign_up")"
  [ "$code" = "200" ] \
    && pass "GET /users/sign_up → 200" \
    || fail "GET /users/sign_up expected 200, got $code (tudu's Users::RegistrationsController is eager-loaded only in production)"

  echo "── Assertion 4: real Devise sign-in behind the proxy (catches assume_ssl/CSRF-Origin, K-439) ──"
  form="$(curl -s -c "$COOKIES" "${SIGNIN_HEADERS[@]}" -H "Accept: text/html" "${BASE}/users/sign_in")"
  token="$(printf '%s' "$form" \
    | grep -o 'name="authenticity_token" value="[^"]*"' \
    | head -1 | sed 's/.*value="//; s/"$//')"
  if [ -z "$token" ]; then
    fail "could not extract CSRF token from sign-in form"
  else
    pass "got CSRF token + session cookie"
    signin_code="$(curl -s -o /dev/null -w '%{http_code}' \
      -c "$COOKIES" -b "$COOKIES" \
      "${SIGNIN_HEADERS[@]}" -H "Origin: ${ORIGIN}" \
      --data-urlencode "authenticity_token=${token}" \
      --data-urlencode "user[email]=alice@example.com" \
      --data-urlencode "user[password]=tudu-demo-password" \
      "${BASE}/users/sign_in")"
    if [ "$signin_code" = "302" ] || [ "$signin_code" = "303" ]; then
      pass "sign-in POST → $signin_code (redirect, not 422 forgery)"
    else
      fail "sign-in POST expected 302/303 redirect, got $signin_code (422 = CSRF-Origin rejection, K-439)"
    fi
    # Signed in, the root switches to the caller's own lists — a DIFFERENT
    # render path from the signed-out board, and the one a human actually uses.
    authed_code="$(curl -s -o /dev/null -w '%{http_code}' \
      -b "$COOKIES" "${SIGNIN_HEADERS[@]}" -H "Accept: text/html" "${BASE}/lists")"
    [ "$authed_code" = "200" ] \
      && pass "signed-in /lists → 200" \
      || fail "signed-in /lists expected 200, got $authed_code"
  fi

  echo "── Assertion 5: JSON POST at the human sign-in form → 422 + Kiosk error envelope (K-459/K-534) ──"
  # The wrong-door signpost this app returns to a JSON-dialing assistant. Only
  # production renders it (dev serves the debug page), and its TEXT is what
  # K-1088 had to correct in seven copies at once.
  signpost="$(curl -s -X POST "${PROXY_HEADERS[@]}" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    --data '{"user":{"email":"probe@example.com","password":"probe"}}' \
    "${BASE}/users/sign_in")"
  signpost_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${PROXY_HEADERS[@]}" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    --data '{"user":{"email":"probe@example.com","password":"probe"}}' \
    "${BASE}/users/sign_in")"
  if [ "$signpost_code" = "422" ] && printf '%s' "$signpost" | grep -q "invalid_authenticity_token"; then
    pass "JSON sign-in POST → 422 + invalid_authenticity_token envelope"
  else
    fail "JSON sign-in POST expected 422 + invalid_authenticity_token envelope, got $signpost_code / '$(printf '%s' "$signpost" | head -c 120)' (K-459 signpost regressed to a bodyless error)"
  fi

  echo "── Assertion 6: unknown path → 404 with a BODY (public/404.html, K-532) ──"
  notfound_len="$(curl -s -o /dev/null -w '%{size_download}' "${PROXY_HEADERS[@]}" \
    -H "Accept: text/html" "${BASE}/this-path-does-not-exist")"
  notfound_code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" \
    -H "Accept: text/html" "${BASE}/this-path-does-not-exist")"
  if [ "$notfound_code" = "404" ] && [ "$notfound_len" -gt 0 ]; then
    pass "unknown path → 404 with ${notfound_len} bytes of body"
  else
    fail "unknown path expected 404 with a non-empty body, got $notfound_code / ${notfound_len} bytes (K-532: no public/404.html → bodyless error)"
  fi

  echo "── Assertion 7: GET /robots.txt and /favicon.ico → 200 statics (T-048) ──"
  robots_code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" "${BASE}/robots.txt")"
  favicon_code="$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_HEADERS[@]}" "${BASE}/favicon.ico")"
  if [ "$robots_code" = "200" ] && [ "$favicon_code" = "200" ]; then
    pass "GET /robots.txt → 200, GET /favicon.ico → 200"
  else
    fail "statics expected 200/200, got robots.txt=$robots_code favicon.ico=$favicon_code (T-048: a missing public/ static puts RoutingError noise back in the journal)"
  fi
}

# $DEMO was validated at the top (before the safety gate ran), so this dispatch
# is total; the catch-all stays as a backstop if a demo is ever added to one
# case and not the other.
case "$DEMO" in
  stylish) smoke_stylish ;;
  prove)   smoke_prove ;;
  tudu)    smoke_tudu ;;
  *) echo "unknown demo '$DEMO' (expected: stylish | prove | tudu)"; exit 2 ;;
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
