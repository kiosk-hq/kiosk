#!/usr/bin/env bash
# Mock AI assistant — exercises the Kiosk wire surface against a running
# kiosk-server. Executed as a bash subprocess by e2e/run.sh after server
# start (not sourced — it runs under its own `set -euo pipefail`).
#
# Asserts on response envelopes from the REST wire surface
# (/kiosk/query, /kiosk/run, /kiosk/pay). Exits non-zero on any failure.
#
# Env (all set by run.sh; the pay-flow + DB assertions dereference them
# under `set -u`, so all are required):
#   SERVER_URL   — e.g. http://127.0.0.1:3001
#   APP_DIR      — the generated Rails app dir (cwd for pay_flow.rb)
#   FIXTURES     — path to e2e/fixtures (locates pay_flow.rb)
#   DB_NAME      — Postgres database for the direct AP2-trail assertions
#   KIOSK_ISSUER — issuer/audience passed through to pay_flow.rb

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

# ─── native discovery: agents.txt / agents.json / agent-configuration ───
#
# The agents.txt v1.0 surface (ROOT-served) plus the RFC 8414-style
# agent-configuration doc, all served by DiscoveryController from the same
# WellKnown model as kiosk.json above (so they cannot drift).

printf "\n\033[1m=== /agents.txt (native agents.txt v1.0) ===\033[0m\n"

# Capture status + headers + body in one request.
at_headers=$(curl -sS -o /tmp/agents_txt_body -D - "$SERVER_URL/agents.txt")
at_status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/agents.txt")
at_body=$(cat /tmp/agents_txt_body)
assert "agents.txt → 200"            "$at_status" "200"
assert "agents.txt Content-Type"     "$(echo "$at_headers" | grep -i '^Content-Type:' | grep -ic 'text/plain')" "1"
assert "agents.txt CORS *"           "$(echo "$at_headers" | grep -i '^Access-Control-Allow-Origin:' | grep -c '\*')" "1"
assert "agents.txt Protocols: ap2"   "$(echo "$at_body" | grep -c '^Protocols: ap2$')" "1"
assert "agents.txt has Skills:"      "$(echo "$at_body" | grep -c '^Skills: ')" "1"

printf "\n\033[1m=== /agents.json (native agents.json v1.0) ===\033[0m\n"

aj_status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/agents.json")
aj_headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/agents.json")
aj=$(curl -sf "$SERVER_URL/agents.json")
assert "agents.json → 200"           "$aj_status" "200"
assert "agents.json Content-Type"    "$(echo "$aj_headers" | grep -i '^Content-Type:' | grep -ic 'application/json')" "1"
assert "agents.json auth.discovery"  "$(echo "$aj" | jq -r '.authorization.discovery')" "/.well-known/agent-configuration"

printf "\n\033[1m=== /.well-known/agent-configuration (agent-auth discovery) ===\033[0m\n"

ac_status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/.well-known/agent-configuration")
ac=$(curl -sf "$SERVER_URL/.well-known/agent-configuration")
assert "agent-configuration → 200"        "$ac_status" "200"
assert "agent-configuration endpoints.register" "$(echo "$ac" | jq -r '.endpoints.register | length > 0')" "true"

printf "\n\033[1m=== /.well-known/api-catalog (RFC 9727 linkset) ===\033[0m\n"

apc_status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/.well-known/api-catalog")
apc_headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/.well-known/api-catalog")
apc=$(curl -sf "$SERVER_URL/.well-known/api-catalog")
assert "api-catalog → 200"           "$apc_status" "200"
assert "api-catalog Content-Type"    "$(echo "$apc_headers" | grep -i '^Content-Type:' | grep -ic 'application/linkset+json')" "1"
assert "api-catalog items non-empty" "$(echo "$apc" | jq -r '.linkset[0].item | length > 0')" "true"

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
alice_appt_id=$(echo "$r" | jq -r '.value.appointment_id')

# Bob books at the same (public) salon so both users own exactly one row.
r=$(exec_call "$BOB_AGENT_TOKEN" "run" "{\"name\":\"book_appointment\",\"salon_id\":$salon_id,\"slot\":\"2026-06-16T10:00:00Z\"}")
assert "bob: ok: true"             "$(echo "$r" | jq -r '.ok')"                    "true"
bob_appt_id=$(echo "$r" | jq -r '.value.appointment_id')

# ─── app-layer per-user isolation (the headline security property) ──────
# my_appointments filters WHERE user_id = kiosk.current_user_id(), where the
# GUC is set from the caller's authenticated identity (bearer token). With
# Alice AND Bob each owning one appointment, prove each principal sees ONLY
# their own row — never the other's — even though both hit the same query.

printf "\n\033[1m=== verify appointment landed + per-user isolation ===\033[0m\n"

alice_appts=$(exec_call "$ALICE_AGENT_TOKEN" "query" '{"name":"my_appointments"}')
assert "alice: 1 appointment exists"  "$(echo "$alice_appts" | jq -r '.rows | length')"                                 "1"
assert "alice: sees her own row"      "$(echo "$alice_appts" | jq -r --arg id "$alice_appt_id" '[.rows[].id] | index($id) != null')" "true"
assert "alice: does NOT see bob's row" "$(echo "$alice_appts" | jq -r --arg id "$bob_appt_id"   '[.rows[].id] | index($id) == null')" "true"

bob_appts=$(exec_call "$BOB_AGENT_TOKEN" "query" '{"name":"my_appointments"}')
assert "bob: 1 appointment exists"    "$(echo "$bob_appts" | jq -r '.rows | length')"                                   "1"
assert "bob: sees his own row"        "$(echo "$bob_appts" | jq -r --arg id "$bob_appt_id"   '[.rows[].id] | index($id) != null')" "true"
assert "bob: does NOT see alice's row" "$(echo "$bob_appts" | jq -r --arg id "$alice_appt_id" '[.rows[].id] | index($id) == null')" "true"

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
# the kiosk-pop JWTs minted by the bundled IdP (register/login/revoke).

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

# ─── account binding: claim ceremony → bound wire → link redeem → unlink ──
#
# The RFC 8628-shaped claim ceremony binds an agent's public key to an
# existing human account (alice); the token poll requires a possession
# proof. Tokens remain kiosk-pop-minted: login is the refresh path, and
# unlink (registration-layer revocation) kills it.
printf "\n\033[1m=== account binding: claim → approve → PoP poll → bound wire → link → unlink ===\033[0m\n"

authmd=$(curl -s -o /dev/null -w '%{http_code}' "$SERVER_URL/auth.md")
assert "binding: /auth.md served"           "$authmd" "200"

bind_out=$( cd "$APP_DIR" && SERVER_URL="$SERVER_URL" KIOSK_ISSUER="$KIOSK_ISSUER" \
              HUMAN_USER_ID="$ALICE" bundle exec ruby "$FIXTURES/claim_flow.rb" )

assert "binding: device_authorization fields" "$(echo "$bind_out" | jq -r '.da_fields')"                            "true"
assert "binding: pending before approval"     "$(echo "$bind_out" | jq -r '.pending | map(tostring) | join(":")')"  "400:authorization_pending"
assert "binding: poll without proof denied"   "$(echo "$bind_out" | jq -r '.no_pop | map(tostring) | join(":")')"   "401:invalid_client"
assert "binding: human approve → 200"         "$(echo "$bind_out" | jq -r '.approve')"                              "200"
assert "binding: fast poll → slow_down"       "$(echo "$bind_out" | jq -r '.slow_down | map(tostring) | join(":")')" "400:slow_down"
assert "binding: token bound to the human"    "$(echo "$bind_out" | jq -r '.bound_user')"                           "true"
assert "binding: wire verb as bound account"  "$(echo "$bind_out" | jq -r '.wire_as_bound | map(tostring) | join(":")')" "200:true"
assert "binding: kiosk-pop login refresh"     "$(echo "$bind_out" | jq -r '.login_bound')"                          "200"
assert "binding: link-code mint (session)"    "$(echo "$bind_out" | jq -r '.link_mint')"                            "201"
assert "binding: link-code redeem → human"    "$(echo "$bind_out" | jq -r '.link_claim | map(tostring) | join(":")')" "201:true"
assert "binding: unlink → 200"                "$(echo "$bind_out" | jq -r '.unlink')"                               "200"
assert "binding: login after unlink → 404"    "$(echo "$bind_out" | jq -r '.login_after_unlink')"                   "404"

# ─── register-PoW golden path (402 pow_required → solve Equihash → 201) ──────
#
# The DoD-2 leg: the agent golden path registers through a REAL register-time
# Equihash proof-of-work (registration_pow_count=1, n=96 k=5), not a toll-free
# shortcut. register_pow_flow.rb proves, in one run: (1) a no-proof register is
# REJECTED 402 pow_required with challenges[], (2) solving each challenge with
# the bundled numpy solver and re-POSTing with pow:{proofs:[...]} SUCCEEDS 201,
# (3) the PoW-minted token authenticates a real wire verb. Same mechanism the
# demos use (kiosk-demo-skooti).
printf "\n\033[1m=== register-PoW golden path: no-proof 402 → solve Equihash → 201 → wire ===\033[0m\n"

reg_out=$( cd "$APP_DIR" && SERVER_URL="$SERVER_URL" KIOSK_ISSUER="$KIOSK_ISSUER" \
             SOLVE_PY="${SOLVE_PY:?SOLVE_PY must be set by run.sh}" \
             bundle exec ruby "$FIXTURES/register_pow_flow.rb" )

assert "register-pow: no-proof → 402"          "$(echo "$reg_out" | jq -r '.no_proof_status')"        "402"
assert "register-pow: code pow_required"       "$(echo "$reg_out" | jq -r '.no_proof_code')"          "pow_required"
assert "register-pow: 1 challenge issued"      "$(echo "$reg_out" | jq -r '.challenges_len')"         "1"
assert "register-pow: solve+proof → registered" "$(echo "$reg_out" | jq -r '.with_proof_registered')" "true"
assert "register-pow: role pinned customer"    "$(echo "$reg_out" | jq -r '.role')"                   "customer"
assert "register-pow: minted token wire → 200" "$(echo "$reg_out" | jq -r '.wire_status')"            "200"
assert "register-pow: minted token wire ok"    "$(echo "$reg_out" | jq -r '.wire_ok')"                "true"

# ─── no-human AP2 pay flow (register → intent → cart → payment mandate → pay → persist) ───
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
