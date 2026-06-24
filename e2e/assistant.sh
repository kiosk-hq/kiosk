#!/usr/bin/env bash
# Mock AI assistant — exercises the Kiosk wire surface against a running
# kiosk-server. Sourced by e2e/run.sh after server start.
#
# Asserts on response envelopes from /kiosk/exec. Exits non-zero on any
# failure.
#
# Env (set by caller):
#   SERVER_URL — e.g. http://127.0.0.1:3001

set -euo pipefail

SERVER_URL="${SERVER_URL:-http://127.0.0.1:3001}"

ALICE="00000000-0000-0000-0000-000000000001"
BOB="00000000-0000-0000-0000-000000000002"

# Bearer-token shape per stub_idp.rb:
#   agent:u-<user_uuid>:a-<agent_id>:r-<role>
ALICE_AGENT_TOKEN="agent:u-$ALICE:a-alice-claude:r-customer"
BOB_AGENT_TOKEN="agent:u-$BOB:a-bob-chatgpt:r-customer"

PASS=0
FAIL=0

assert() {
  local label="$1"
  local actual="$2"
  local expected="$3"

  if [ "$actual" = "$expected" ]; then
    printf "  \033[1;32m✓\033[0m %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "  \033[1;31m✗\033[0m %s\n     expected: %s\n     actual:   %s\n" \
      "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

exec_call() {
  local token="$1"
  local body="$2"
  curl -sS -X POST "$SERVER_URL/kiosk/exec" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body"
}

# ─── well-known discovery ───────────────────────────────────────────────

printf "\n\033[1m=== /.well-known/kiosk.json ===\033[0m\n"

wk=$(curl -sf "$SERVER_URL/.well-known/kiosk.json")
assert "kiosk.version present"     "$(echo "$wk" | jq -r '.kiosk.version')"     "1.0"
assert "kiosk.endpoint correct"    "$(echo "$wk" | jq -r '.kiosk.endpoint')"    "$SERVER_URL/kiosk"
assert "kiosk.auth.kind oauth2"    "$(echo "$wk" | jq -r '.kiosk.auth.kind')"   "oauth2"
assert "kiosk.issuer set"          "$(echo "$wk" | jq -r '.kiosk.issuer')"      "$SERVER_URL"
assert "kiosk.capabilities[]"      "$(echo "$wk" | jq -r '.kiosk.capabilities | length')" "4"

# ─── Kiosk-* response headers ───────────────────────────────────────────

printf "\n\033[1m=== response headers ===\033[0m\n"

headers=$(curl -sS -o /dev/null -D - -X POST "$SERVER_URL/kiosk/exec" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"sql","body":{"sql":"SELECT 1 AS one"}}')

assert "Kiosk-Server-Version present" "$(echo "$headers" | grep -i '^Kiosk-Server-Version:' | wc -l | tr -d ' ')" "1"
assert "Kiosk-API-Version present"    "$(echo "$headers" | grep -i '^Kiosk-API-Version:'    | wc -l | tr -d ' ')" "1"
assert "Kiosk-Min-Client present"     "$(echo "$headers" | grep -i '^Kiosk-Min-Client:'     | wc -l | tr -d ' ')" "1"

# ─── sql verb ───────────────────────────────────────────────────────────

printf "\n\033[1m=== sql verb ===\033[0m\n"

r=$(exec_call "$ALICE_AGENT_TOKEN" '{"command":"sql","body":{"sql":"SELECT id, name FROM salons ORDER BY id"}}')
assert "ok: true"                  "$(echo "$r" | jq -r '.ok')"                    "true"
assert "kind: rows"                "$(echo "$r" | jq -r '.kind')"                  "rows"
assert "exactly 1 salon"           "$(echo "$r" | jq -r '.rows | length')"         "1"
assert "salon name is Combette"      "$(echo "$r" | jq -r '.rows[0].name')"          "Combette on Park"

# ─── run verb (book_appointment Action) ─────────────────────────────────

printf "\n\033[1m=== run verb — book_appointment ===\033[0m\n"

# Get salon id first.
salon_id=$(exec_call "$ALICE_AGENT_TOKEN" '{"command":"sql","body":{"sql":"SELECT id FROM salons LIMIT 1"}}' | jq -r '.rows[0].id')

r=$(exec_call "$ALICE_AGENT_TOKEN" "{\"command\":\"run\",\"body\":{\"name\":\"book_appointment\",\"salon_id\":$salon_id,\"slot\":\"2026-06-15T14:00:00Z\"}}")
assert "ok: true"                  "$(echo "$r" | jq -r '.ok')"                    "true"
assert "kind: value"               "$(echo "$r" | jq -r '.kind')"                  "value"
assert "appointment_id returned"   "$(echo "$r" | jq -r '.value.appointment_id | length > 0')" "true"
assert "salon_id echoed"           "$(echo "$r" | jq -r ".value.salon_id")"        "$salon_id"

# ─── appointment landed in DB ───────────────────────────────────────────

printf "\n\033[1m=== verify appointment landed ===\033[0m\n"

r=$(exec_call "$ALICE_AGENT_TOKEN" '{"command":"sql","body":{"sql":"SELECT COUNT(*)::int AS c FROM appointments"}}')
assert "1 appointment exists"      "$(echo "$r" | jq -r '.rows[0].c')"             "1"

# ─── error envelopes ────────────────────────────────────────────────────

printf "\n\033[1m=== error envelopes ===\033[0m\n"

# Unknown verb → BadRequest, http 400, code bad_request
status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/exec" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"frobnicate","body":{}}')
assert "unknown verb → 400"        "$status" "400"

r=$(exec_call "$ALICE_AGENT_TOKEN" '{"command":"frobnicate","body":{}}')
assert "ok: false on bad verb"     "$(echo "$r" | jq -r '.ok')"                "false"
assert "error.code bad_request"    "$(echo "$r" | jq -r '.error.code')"        "bad_request"

# Unknown action name → NotFound, http 404, code not_found
status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/exec" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"run","body":{"name":"nope"}}')
assert "unknown action → 404"      "$status" "404"

# Missing Authorization → Unauthenticated, http 401
status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/exec" \
  -H "Content-Type: application/json" \
  -d '{"command":"sql","body":{"sql":"SELECT 1"}}')
assert "no auth → 401"             "$status" "401"

# Stub IdP returns nil for unknown token shape → 401
status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/exec" \
  -H "Authorization: Bearer garbage" \
  -H "Content-Type: application/json" \
  -d '{"command":"sql","body":{"sql":"SELECT 1"}}')
assert "garbage token → 401"       "$status" "401"

# ─── JWKS endpoint ──────────────────────────────────────────────────────
#
# /kiosk/.well-known/jwks.json publishes the RSA public key that signs
# JWTs issued by the bundled IdP and OAuth surface (spec §3.5, §6.2).

printf "\n\033[1m=== /kiosk/.well-known/jwks.json ===\033[0m\n"

jwks=$(curl -sf "$SERVER_URL/kiosk/.well-known/jwks.json")
assert "jwks: keys[] present"          "$(echo "$jwks" | jq -r '.keys | length')"          "1"
assert "jwks: kty=RSA"                 "$(echo "$jwks" | jq -r '.keys[0].kty')"            "RSA"
assert "jwks: use=sig"                 "$(echo "$jwks" | jq -r '.keys[0].use')"            "sig"
assert "jwks: alg=RS256"               "$(echo "$jwks" | jq -r '.keys[0].alg')"            "RS256"
assert "jwks: kid present"             "$(echo "$jwks" | jq -r '.keys[0].kid | length > 0')" "true"
assert "jwks: n (modulus) present"     "$(echo "$jwks" | jq -r '.keys[0].n | length > 0')"   "true"
assert "jwks: e (exponent) present"    "$(echo "$jwks" | jq -r '.keys[0].e | length > 0')"   "true"
# Never leak private parameters.
assert "jwks: no private d field"      "$(echo "$jwks" | jq -r '.keys[0] | has("d")')"      "false"
assert "jwks: no private p field"      "$(echo "$jwks" | jq -r '.keys[0] | has("p")')"      "false"

# ─── OAuth 2.1 Device Authorization Grant (RFC 8628) ───────────────────
#
# Full polling-flow exercise:
#   1) client POSTs /oauth/device_authorization → gets device_code + user_code
#   2) client polls /oauth/token while pending → authorization_pending
#   3) test fixture simulates user approval (real flow uses verify HTML form)
#   4) client polls again → access_token (JWT)
#   5) JWT used against /kiosk/exec → ExecController authenticates via the
#      JWT-aware composite IdP, sql call succeeds with the JWT's `sub` user

printf "\n\033[1m=== oauth device_authorization (RFC 8628) ===\033[0m\n"

# Step 1 — initiate device authorization.
da_resp=$(curl -sS -X POST "$SERVER_URL/kiosk/oauth/device_authorization" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=kiosk-cli-e2e" \
  --data-urlencode "role=customer")

DEVICE_CODE=$(echo "$da_resp" | jq -r '.device_code')
USER_CODE=$(echo "$da_resp"   | jq -r '.user_code')

assert "device_authorization: device_code present"      "$(echo "$da_resp" | jq -r '.device_code | length > 0')"      "true"
assert "device_authorization: user_code XXXX-XXXX form" "$(echo "$USER_CODE" | grep -cE '^[A-Z0-9]{4}-[A-Z0-9]{4}$' | tr -d ' ')" "1"
assert "device_authorization: verification_uri"         "$(echo "$da_resp" | jq -r '.verification_uri')"                "$SERVER_URL/kiosk/oauth/device/verify"
assert "device_authorization: verification_uri_complete contains code" \
                                                        "$(echo "$da_resp" | jq -r '.verification_uri_complete')"       "$SERVER_URL/kiosk/oauth/device/verify?user_code=$USER_CODE"
assert "device_authorization: expires_in=900"           "$(echo "$da_resp" | jq -r '.expires_in')"                      "900"
assert "device_authorization: interval=5"               "$(echo "$da_resp" | jq -r '.interval')"                        "5"

# Step 2 — poll while pending.
poll1=$(curl -sS -X POST "$SERVER_URL/kiosk/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
  --data-urlencode "device_code=$DEVICE_CODE")

assert "token poll (pending): error=authorization_pending" "$(echo "$poll1" | jq -r '.error')" "authorization_pending"

# Step 3 — simulate user approval via test fixture.
approve=$(curl -sS -X POST "$SERVER_URL/kiosk/_test/device_authorization/approve" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "user_code=$USER_CODE" \
  --data-urlencode "user_id=$ALICE")

assert "test fixture: approval recorded"                "$(echo "$approve" | jq -r '.status')" "approved"

# Step 4 — poll after approval → get the JWT.
poll2=$(curl -sS -X POST "$SERVER_URL/kiosk/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
  --data-urlencode "device_code=$DEVICE_CODE")

ACCESS_TOKEN=$(echo "$poll2" | jq -r '.access_token')
assert "token poll (approved): token_type=Bearer"       "$(echo "$poll2" | jq -r '.token_type')"  "Bearer"
assert "token poll (approved): expires_in=3600"         "$(echo "$poll2" | jq -r '.expires_in')"  "3600"
assert "token poll (approved): scope=customer"          "$(echo "$poll2" | jq -r '.scope')"       "customer"
assert "token poll (approved): JWT compact serialised"  "$(echo "$ACCESS_TOKEN" | awk -F. '{print NF-1}')" "2"

# Step 5 — second poll of same device_code returns invalid_grant (consumed).
poll3=$(curl -sS -X POST "$SERVER_URL/kiosk/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
  --data-urlencode "device_code=$DEVICE_CODE")
assert "token poll (replay): error=invalid_grant"       "$(echo "$poll3" | jq -r '.error')"       "invalid_grant"

# Step 6 — use the JWT against /kiosk/exec.
exec_with_jwt=$(curl -sS -X POST "$SERVER_URL/kiosk/exec" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"sql","body":{"sql":"SELECT id, name FROM salons ORDER BY id"}}')
assert "exec via OAuth JWT: ok=true"                    "$(echo "$exec_with_jwt" | jq -r '.ok')"             "true"
assert "exec via OAuth JWT: returns rows"               "$(echo "$exec_with_jwt" | jq -r '.kind')"           "rows"
assert "exec via OAuth JWT: salon present"              "$(echo "$exec_with_jwt" | jq -r '.rows[0].name')"   "Combette on Park"

# Step 7 — bad grant_type → unsupported_grant_type.
bad_grant=$(curl -sS -X POST "$SERVER_URL/kiosk/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=x")
assert "token unsupported grant_type"                   "$(echo "$bad_grant" | jq -r '.error')"   "unsupported_grant_type"

# Step 8 — missing client_id → invalid_request.
no_client=$(curl -sS -X POST "$SERVER_URL/kiosk/oauth/device_authorization" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "role=customer")
assert "device_authorization no client_id: invalid_request" "$(echo "$no_client" | jq -r '.error')" "invalid_request"

# ─── kiosk-cli end-to-end ───────────────────────────────────────────────
#
# Re-run a subset of the assertions above through the POSIX shell `kiosk`
# binary instead of raw curl. Proves the CLI's wire shape matches the
# server's wire shape — and that exit codes map to error envelopes per
# spec §5.2.

printf "\n\033[1m=== via kiosk-cli ===\033[0m\n"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KIOSK_BIN="$SCRIPT_DIR/../kiosk-cli/bin/kiosk"

if [ ! -x "$KIOSK_BIN" ]; then
  printf "  \033[1;33m⚠\033[0m kiosk-cli not found at %s — skipping CLI assertions\n" "$KIOSK_BIN"
else
  # Token resolution via the per-host env var. The host normalises to
  # `127_0_0_1_3001`, so the matching env-var name is
  # KIOSK_TOKEN_127_0_0_1_3001.
  export KIOSK_TOKEN_127_0_0_1_3001="$ALICE_AGENT_TOKEN"

  # well-known via the CLI
  wk=$("$KIOSK_BIN" "$SERVER_URL" well-known)
  assert "cli: well-known kiosk.version"   "$(echo "$wk" | jq -r '.kiosk.version')"    "1.0"
  assert "cli: well-known kiosk.endpoint"  "$(echo "$wk" | jq -r '.kiosk.endpoint')"   "$SERVER_URL/kiosk"

  # sql verb via the CLI
  r=$("$KIOSK_BIN" "$SERVER_URL" sql "SELECT id, name FROM salons ORDER BY id")
  assert "cli: sql ok=true"                "$(echo "$r" | jq -r '.ok')"                "true"
  assert "cli: sql kind=rows"              "$(echo "$r" | jq -r '.kind')"              "rows"
  assert "cli: sql salon name"             "$(echo "$r" | jq -r '.rows[0].name')"      "Combette on Park"

  # run verb via the CLI with k=v args
  salon_id=$(echo "$r" | jq -r '.rows[0].id')
  r=$("$KIOSK_BIN" "$SERVER_URL" run book_appointment \
        "salon_id=$salon_id" "slot=2026-06-15T15:00:00Z")
  assert "cli: run ok=true"                "$(echo "$r" | jq -r '.ok')"                "true"
  assert "cli: run kind=value"             "$(echo "$r" | jq -r '.kind')"              "value"
  assert "cli: run salon_id echoed"        "$(echo "$r" | jq -r '.value.salon_id')"    "$salon_id"

  # The assertions below check non-zero exit codes; `set -e` would
  # otherwise abort the script before $? is captured. Disable it locally.
  set +e

  # exit-code mapping: unknown action → not_found (code 2)
  "$KIOSK_BIN" "$SERVER_URL" run nope >/dev/null 2>&1
  rc=$?
  assert "cli: unknown action → exit 2"    "$rc" "2"

  # exit-code mapping: bad verb (command) → bad_request (code 2)
  # We can't trigger bad_request from a known CLI verb directly — every CLI
  # verb produces a valid command. So this assertion stays at HTTP-level
  # (covered by the curl block above).

  # exit-code mapping: bad token → unauthenticated (code 3)
  KIOSK_TOKEN_127_0_0_1_3001=garbage \
    "$KIOSK_BIN" "$SERVER_URL" sql "SELECT 1" >/dev/null 2>&1
  rc=$?
  assert "cli: garbage token → exit 3"     "$rc" "3"

  # Token resolution: with NO env var set and no ~/.kiosk/credentials,
  # the CLI should exit 3 once it tries to talk to /exec.
  (
    unset KIOSK_TOKEN KIOSK_TOKEN_127_0_0_1_3001
    HOME=$(mktemp -d)
    "$KIOSK_BIN" "$SERVER_URL" sql "SELECT 1" >/dev/null 2>&1
  )
  rc=$?
  assert "cli: no token → exit 3"          "$rc" "3"

  set -e

  # ─── kiosk login (full Device Grant flow via CLI) ─────────────────────
  #
  # End-to-end exercise of the marquee `kiosk login` flow:
  #   1) CLI invokes /oauth/device_authorization, prints user_code
  #   2) test harness reads user_code from CLI's stdout
  #   3) test harness POSTs the /_test/approve fixture (simulates the
  #      human typing code at /oauth/device/verify and clicking Allow)
  #   4) CLI's next poll receives the JWT
  #   5) CLI writes ~/.kiosk/credentials with the token
  #   6) CLI exits 0
  #   7) test asserts the persisted token works for /kiosk/exec

  printf "\n\033[1m=== kiosk login (Device Grant CLI flow) ===\033[0m\n"

  LOGIN_HOME=$(mktemp -d)
  LOGIN_LOG=$(mktemp)

  # CLI runs in background with isolated HOME so the host's real
  # ~/.kiosk/credentials is untouched. KIOSK_NO_BROWSER skips the
  # `open` / `xdg-open` auto-launch.
  (
    HOME="$LOGIN_HOME" \
      KIOSK_NO_BROWSER=1 \
      "$KIOSK_BIN" "$SERVER_URL" login >"$LOGIN_LOG" 2>&1
    echo $? >"$LOGIN_LOG.rc"
  ) &
  LOGIN_PID=$!

  # Wait for the CLI to emit the user_code (XXXX-XXXX shape).
  CAPTURED_CODE=""
  for _ in $(seq 1 30); do
    if [ -s "$LOGIN_LOG" ]; then
      CAPTURED_CODE=$(grep -oE '[A-Z0-9]{4}-[A-Z0-9]{4}' "$LOGIN_LOG" | head -1 || true)
      [ -n "$CAPTURED_CODE" ] && break
    fi
    sleep 0.5
  done

  assert "login: CLI emitted user_code" \
    "$(echo "${CAPTURED_CODE:-}" | grep -cE '^[A-Z0-9]{4}-[A-Z0-9]{4}$' | tr -d ' ')" "1"

  # Simulate user approval at /oauth/device/verify.
  approve_resp=$(curl -sS -X POST "$SERVER_URL/kiosk/_test/device_authorization/verify" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "decision=approve" \
    --data-urlencode "user_code=$CAPTURED_CODE" \
    --data-urlencode "user_id=$ALICE")
  assert "login: approval recorded" "$(echo "$approve_resp" | jq -r '.status')" "approved"

  # Wait for the CLI to notice the approval and finish (≤ poll-interval+1).
  for _ in $(seq 1 30); do
    kill -0 "$LOGIN_PID" 2>/dev/null || break
    sleep 1
  done

  if kill -0 "$LOGIN_PID" 2>/dev/null; then
    kill "$LOGIN_PID" 2>/dev/null || true
    fail_login="CLI did not finish within 30s; killed"
    LOGIN_RC=999
  else
    wait "$LOGIN_PID" 2>/dev/null || true
    LOGIN_RC=$(cat "$LOGIN_LOG.rc" 2>/dev/null || echo "?")
  fi

  assert "login: CLI exit 0"               "$LOGIN_RC" "0"
  assert "login: token persisted to ~/.kiosk/credentials" \
    "$(jq -r --arg h "$SERVER_URL" '.[$h].token != null and (.[$h].token | length > 0)' \
        "$LOGIN_HOME/.kiosk/credentials" 2>/dev/null)" "true"

  # Verify the persisted token actually works against /kiosk/exec.
  PERSISTED_TOKEN=$(jq -r --arg h "$SERVER_URL" '.[$h].token' "$LOGIN_HOME/.kiosk/credentials")
  exec_with_persisted=$(curl -sS -X POST "$SERVER_URL/kiosk/exec" \
    -H "Authorization: Bearer $PERSISTED_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"command":"sql","body":{"sql":"SELECT 1 AS one"}}')
  assert "login: persisted token authenticates /kiosk/exec" \
    "$(echo "$exec_with_persisted" | jq -r '.ok')" "true"

  rm -rf "$LOGIN_HOME" "$LOGIN_LOG" "$LOGIN_LOG.rc"
fi

# ─── no-human AP2 pay flow (register → intent+cart mandate → pay → persist) ───
printf "\n\033[1m=== no-human register → mandate → pay ===\033[0m\n"

pay_out=$( cd "$APP_DIR" && SERVER_URL="$SERVER_URL" KIOSK_ISSUER="$KIOSK_ISSUER" \
             bundle exec ruby "$FIXTURES/pay_flow.rb" )

assert "pay: http 200"                "$(echo "$pay_out" | jq -r '.http_code')"                       "200"
assert "pay: ok=true"                 "$(echo "$pay_out" | jq -r '.response.ok')"                     "true"
assert "pay: kind=value"              "$(echo "$pay_out" | jq -r '.response.kind')"                   "value"
assert "pay: psp_reference present"   "$(echo "$pay_out" | jq -r '.response.value.psp_reference | length > 0')" "true"
assert "pay: settled 1599"            "$(echo "$pay_out" | jq -r '.response.value.settled_amount_cents')" "1599"
assert "pay: payment_mandate_id"      "$(echo "$pay_out" | jq -r '.response.value.payment_mandate_id | length > 0')" "true"

# The full AP2 trail landed in Postgres — one row each, no human anywhere.
assert "db: 1 intent_mandate"         "$(psql -X -d "$DB_NAME" -tAc 'SELECT COUNT(*) FROM kiosk.intent_mandates')"   "1"
assert "db: 1 cart_mandate"           "$(psql -X -d "$DB_NAME" -tAc 'SELECT COUNT(*) FROM kiosk.cart_mandates')"     "1"
assert "db: 1 payment_mandate"        "$(psql -X -d "$DB_NAME" -tAc 'SELECT COUNT(*) FROM kiosk.payment_mandates')"  "1"
assert "db: settlement amount 1599"   "$(psql -X -d "$DB_NAME" -tAc 'SELECT settled_amount_cents FROM kiosk.payment_mandates LIMIT 1')" "1599"

# ─── summary ────────────────────────────────────────────────────────────

printf "\n\033[1m=== summary ===\033[0m\n"
printf "  pass: %s\n  fail: %s\n" "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ] || exit 1
