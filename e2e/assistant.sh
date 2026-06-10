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
assert "salon name is Sweepy"      "$(echo "$r" | jq -r '.rows[0].name')"          "Sweepy on Park"

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
  assert "cli: sql salon name"             "$(echo "$r" | jq -r '.rows[0].name')"      "Sweepy on Park"

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
fi

# ─── summary ────────────────────────────────────────────────────────────

printf "\n\033[1m=== summary ===\033[0m\n"
printf "  pass: %s\n  fail: %s\n" "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ] || exit 1
