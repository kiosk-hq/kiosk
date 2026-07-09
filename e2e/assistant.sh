#!/usr/bin/env bash
# Mock AI assistant — exercises the Kiosk wire surface against a running
# kiosk-server. Sourced by e2e/run.sh after server start.
#
# Asserts on response envelopes from the REST wire surface
# (/kiosk/query, /kiosk/run, /kiosk/pay). Exits non-zero on any failure.
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
  local verb="$2"
  local body="$3"
  local url="$SERVER_URL/kiosk/$verb"
  curl -sS -X POST "$url" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body"
}

exec_json() {
  # Generic POST to an arbitrary kiosk path.
  local token="$1"
  local path="$2"
  local body="$3"
  curl -sS -X POST "$SERVER_URL$path" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body"
}

# ─── well-known discovery ───────────────────────────────────────────────

printf "\n\033[1m=== /.well-known/kiosk.json ===\033[0m\n"

wk=$(curl -sf "$SERVER_URL/.well-known/kiosk.json")
assert "kiosk.version present"     "$(echo "$wk" | jq -r '.kiosk.version')"     "1.0"
assert "kiosk.endpoint correct"    "$(echo "$wk" | jq -r '.kiosk.endpoint')"    "$SERVER_URL/kiosk"
assert "kiosk.auth.kind kiosk-pop" "$(echo "$wk" | jq -r '.kiosk.auth.kind')"   "kiosk-pop"
assert "kiosk.auth.challenge_url"  "$(echo "$wk" | jq -r '.kiosk.auth.challenge_url')" "$SERVER_URL/kiosk/auth/challenge"
assert "kiosk.issuer set"          "$(echo "$wk" | jq -r '.kiosk.issuer')"      "$SERVER_URL"
assert "kiosk.capabilities[]"      "$(echo "$wk" | jq -r '.kiosk.capabilities | join(",")')" "schema,query,run,pay"

# ─── Kiosk-* response headers ───────────────────────────────────────────

printf "\n\033[1m=== response headers ===\033[0m\n"

headers=$(curl -sS -o /dev/null -D - -X POST "$SERVER_URL/kiosk/query" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"salons"}')

assert "Kiosk-Server-Version present" "$(echo "$headers" | grep -i '^Kiosk-Server-Version:' | wc -l | tr -d ' ')" "1"
assert "Kiosk-API-Version present"    "$(echo "$headers" | grep -i '^Kiosk-API-Version:'    | wc -l | tr -d ' ')" "1"
assert "Kiosk-Min-Client present"     "$(echo "$headers" | grep -i '^Kiosk-Min-Client:'     | wc -l | tr -d ' ')" "1"

# ─── query verb ─────────────────────────────────────────────────────────

printf "\n\033[1m=== query verb ===\033[0m\n"

r=$(exec_call "$ALICE_AGENT_TOKEN" "query" '{"name":"salons"}')
assert "ok: true"                  "$(echo "$r" | jq -r '.ok')"                    "true"
assert "kind: rows"                "$(echo "$r" | jq -r '.kind')"                  "rows"
assert "exactly 1 salon"           "$(echo "$r" | jq -r '.rows | length')"         "1"
assert "salon name is Combette"      "$(echo "$r" | jq -r '.rows[0].name')"          "Combette on Park"

# ─── run verb (book_appointment Action) ─────────────────────────────────

printf "\n\033[1m=== run verb — book_appointment ===\033[0m\n"

# Get salon id first.
salon_id=$(exec_call "$ALICE_AGENT_TOKEN" "query" '{"name":"salons"}' | jq -r '.rows[0].id')

r=$(exec_call "$ALICE_AGENT_TOKEN" "run" "{\"name\":\"book_appointment\",\"salon_id\":$salon_id,\"slot\":\"2026-06-15T14:00:00Z\"}")
assert "ok: true"                  "$(echo "$r" | jq -r '.ok')"                    "true"
assert "kind: value"               "$(echo "$r" | jq -r '.kind')"                  "value"
assert "appointment_id returned"   "$(echo "$r" | jq -r '.value.appointment_id | length > 0')" "true"
assert "salon_id echoed"           "$(echo "$r" | jq -r '.value.salon_id')"        "$salon_id"

# ─── appointment landed in DB ───────────────────────────────────────────

printf "\n\033[1m=== verify appointment landed ===\033[0m\n"

r=$(exec_call "$ALICE_AGENT_TOKEN" "query" '{"name":"my_appointments"}')
assert "1 appointment exists"      "$(echo "$r" | jq -r '.rows | length')"          "1"

# ─── error envelopes ────────────────────────────────────────────────────

printf "\n\033[1m=== error envelopes ===\033[0m\n"

# Unknown query name → NotFound, http 404, code not_found
status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/query" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"frobnicate"}')
assert "unknown query → 404"        "$status" "404"

r=$(exec_call "$ALICE_AGENT_TOKEN" "query" '{"name":"frobnicate"}')
assert "ok: false on bad query"     "$(echo "$r" | jq -r '.ok')"                "false"
assert "error.code not_found"       "$(echo "$r" | jq -r '.error.code')"        "not_found"

# Unknown action name → NotFound, http 404, code not_found
status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/run" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"nope"}')
assert "unknown action → 404"      "$status" "404"

# Missing Authorization → Unauthenticated, http 401
status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/query" \
  -H "Content-Type: application/json" \
  -d '{"name":"salons"}')
assert "no auth → 401"             "$status" "401"

# Stub IdP returns nil for unknown token shape → 401
status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/query" \
  -H "Authorization: Bearer garbage" \
  -H "Content-Type: application/json" \
  -d '{"name":"salons"}')
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

# ─── OAuth 2.1 Device Authorization Grant — intentionally NOT exercised ──
#
# The device-grant surface (/oauth/device_authorization, /oauth/token) ships
# in kiosk-server but stays DORMANT per ADR-0008: Kiosk auth is the
# proof-of-possession challenge-response handshake (see well-known assertions
# above), not OAuth. The device-grant code is retained for a possible future
# human-in-the-loop consent flow but is not part of the advertised surface, so
# e2e does not assert on it (findings K-016 / K-023).

# ─── no-human AP2 pay flow (register → intent+cart mandate → pay → persist) ───
printf "\n\033[1m=== no-human register → mandate → pay ===\033[0m\n"

pay_out=$( cd "$APP_DIR" && SERVER_URL="$SERVER_URL" KIOSK_ISSUER="$KIOSK_ISSUER" \
             bundle exec ruby "$FIXTURES/pay_flow.rb" )

assert "pay: http 200"                "$(echo "$pay_out" | jq -r '.http_code')"                       "200"
assert "pay: ok=true"                 "$(echo "$pay_out" | jq -r '.response.ok')"                     "true"
assert "pay: kind=value"              "$(echo "$pay_out" | jq -r '.response.kind')"                   "value"
assert "pay: psp_reference present"   "$(echo "$pay_out" | jq -r '.response.value.psp_reference | length > 0')" "true"
assert "pay: settled 1599"            "$(echo "$pay_out" | jq -r '.response.value.settled_amount_cents')" "1599"
assert "pay: settlement_id"           "$(echo "$pay_out" | jq -r '.response.value.settlement_id | length > 0')" "true"

# The full AP2 trail landed in Postgres — one row each, no human anywhere.
assert "db: 1 intent_mandate"         "$(psql -X -d "$DB_NAME" -tAc 'SELECT COUNT(*) FROM kiosk.intent_mandates')"   "1"
assert "db: 1 cart_mandate"           "$(psql -X -d "$DB_NAME" -tAc 'SELECT COUNT(*) FROM kiosk.cart_mandates')"     "1"
assert "db: 1 payment_mandate"        "$(psql -X -d "$DB_NAME" -tAc 'SELECT COUNT(*) FROM kiosk.payment_mandates')"  "1"
assert "db: settlement amount 1599"   "$(psql -X -d "$DB_NAME" -tAc 'SELECT settled_amount_cents FROM kiosk.settlements LIMIT 1')" "1599"

# ─── summary ────────────────────────────────────────────────────────────

printf "\n\033[1m=== summary ===\033[0m\n"
printf "  pass: %s\n  fail: %s\n" "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ] || exit 1
