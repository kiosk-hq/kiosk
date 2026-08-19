#!/usr/bin/env bash
# Mock AI assistant — exercises the Kiosk wire surface against a running
# kiosk-server. Executed as a bash subprocess by e2e/run.sh after server
# start (not sourced — it runs under its own `set -euo pipefail`).
#
# Asserts on responses from the REST wire surface: the 0.4 per-verb endpoints
# (GET /kiosk/<query-name>, POST /kiosk/<action-name>), /kiosk/pay, and —
# until the 0.4 cutover slice deletes them — the 0.3 name-dispatch endpoints
# one endpoint per verb. Exits non-zero on any failure.
#
# ONE ANSWER SHAPE (T-074 = A, the cutover). Every endpoint answers the 0.4
# shape: the handler's payload VERBATIM on success (a bare array, `{rows,
# next}` when paginated, the action's own object), an RFC 9457 problem document
# on an error. `POST /kiosk/{query,run}` do not exist; `schema` and `pay`
# answer the same shape as the per-verb wire. (This header described a
# two-shape intermediate until the cutover landed.)
#
# ONE AUTH SHAPE, WITH ONE DELIBERATE EXCEPTION. Everything under the mount is
# Bearer-gated except `GET /kiosk/schema`, which is public (T-094) — and
# `/kiosk/openapi.json`, which is still gated on purpose while K-804 is open.
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

# ── The 0.4 per-verb wire ───────────────────────────────────────────────
#
# A query is a GET at its own path and carries its arguments in the query
# string; an action is a POST at its own path and carries them in a JSON
# body. That is the whole invocation — no `name` field, no multiplexing
# endpoint.

query_call() {
  # query_call <token> <query-name> [query-string]
  local token="$1"
  local name="$2"
  local qs="${3:-}"
  local url="$SERVER_URL/kiosk/$name"
  [ -n "$qs" ] && url="$url?$qs"
  curl -sS "$url" \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/json"
}

action_call() {
  # action_call <token> <action-name> <json-body>
  local token="$1"
  local name="$2"
  local body="$3"
  curl -sS -X POST "$SERVER_URL/kiosk/$name" \
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
# `capabilities` names the MODULES this origin serves, not its verbs
# (T-068 slice 5, T-075 = A, ADR-0025).
assert "kiosk.capabilities[]"      "$(echo "$wk" | jq -r '.kiosk.capabilities | join(",")')" "schema,queries,actions,pay"
# THE CACHE-BUSTED CATALOG LINK (T-094). This document is the SHORT-lived half
# of the pair: it expires in minutes and republishes the link, which is what
# lets the link itself be cached for a year.
assert "kiosk.schema_url is digest-versioned" \
  "$(echo "$wk" | jq -r '.kiosk.schema_url' | grep -Ec "^$SERVER_URL/kiosk/schema\?v=[0-9a-f]{32}\$")" "1"
assert "…and kiosk.json itself expires quickly" \
  "$(curl -sS -o /dev/null -D - "$SERVER_URL/.well-known/kiosk.json" | grep -ic '^Cache-Control: max-age=300, public')" "1"

# THE FLEET OF PUBLIC DOCUMENTS, SPLIT IN TWO — and the split is the point
# (T-093, 2026-08-19).
#
# Until that date this was ONE loop over FIVE documents asserting that none of
# them named a verb, because the catalogue was Bearer-gated and three separate
# defences depended on it staying that way. Phil retired the premise: «на
# статичных GET endpoint'ах — пожалуйста… Пускай долбятся в них сколько хотят
# без аутентификации». So the api-catalog now MUST name every verb, and the
# other four still must not — for a different reason, which is that they are
# POINTERS and not copies of the contract (T-075 = A). Both halves are asserted
# POSITIVELY below; "no longer refuses to publish" would be a green nothing.
#
# NON-VACUITY, COMMITTED RATHER THAN PROVED ONCE BY HAND. Slice 5 checked this
# loop was not vacuous by temporarily adding a token that IS present and
# watching it fail. That property is now a permanent CONTROL: every one of
# these documents names this origin, so if a fetch or a grep silently stopped
# working the control fails and the "0" assertions stop meaning nothing.
for public_doc in "/.well-known/kiosk.json" "/agents.json" "/agents.txt" "/.well-known/agent-configuration"; do
  body=$(curl -sf "$SERVER_URL$public_doc")
  assert "$public_doc is really being read (control token)" \
    "$(echo "$body" | grep -qF "$SERVER_URL" && echo present || echo MISSING)" "present"
  for verb_name in salons my_appointments book_appointment; do
    assert "$public_doc names no verb ($verb_name) — pointer, not copy" \
      "$(echo "$body" | grep -c "$verb_name" || true)" "0"
  done
done

# THE INVERSE, on the fifth document. Every verb, at its real per-verb 0.4
# endpoint, with the method that reaches it — anonymously.
apc_body=$(curl -sf "$SERVER_URL/.well-known/api-catalog")
for verb_name in salons my_appointments book_appointment; do
  assert "api-catalog hyperlinks $verb_name, unauthenticated" \
    "$(echo "$apc_body" | jq -r --arg h "$SERVER_URL/kiosk/$verb_name" \
        '[.linkset[0].item[] | select(.href == $h)] | length')" "1"
done
assert "…a query is advertised GET" \
  "$(echo "$apc_body" | jq -r --arg h "$SERVER_URL/kiosk/salons" \
      '.linkset[0].item[] | select(.href == $h) | ."kiosk-method" | join(",")')" "GET"
assert "…an action is advertised POST" \
  "$(echo "$apc_body" | jq -r --arg h "$SERVER_URL/kiosk/book_appointment" \
      '.linkset[0].item[] | select(.href == $h) | ."kiosk-method" | join(",")')" "POST"

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
# x-kiosk carries POINTERS, not a copy of the contract: it stopped echoing
# `capabilities` under `wire.verbs` (T-075 = A).
assert "agents.json x-kiosk keys"    "$(echo "$aj" | jq -r '."x-kiosk" | keys_unsorted | join(",")')" "schema,api_catalog,mount_path,api_version"
# The pointer carries the boot digest as `?v=` (T-094) — the cache-busting
# half, without which a week-long TTL on a fixed URL is a stale catalogue.
assert "agents.json x-kiosk.schema is digest-versioned" \
  "$(echo "$aj" | jq -r '."x-kiosk".schema' | grep -Ec '^/kiosk/schema\?v=[0-9a-f]{32}$')" "1"
assert "agents.json x-kiosk has no wire.verbs echo" "$(echo "$aj" | jq -r '."x-kiosk" | has("wire")')" "false"

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

# ─── the DERIVED OpenAPI document (T-068 slice 4, T-071 = C) ────────────
#
# A SECOND renderer over the registry `GET /kiosk/schema` renders. It is for
# TOOLING, it is named nowhere in skill.md, and it is PROVISIONAL — so what is
# asserted here is only that it is served, that it is gated exactly as the
# canonical catalog is, and that it says the four things the T-086 research
# measured it must. Nothing in this harness may come to DEPEND on it.

printf "\n\033[1m=== GET /kiosk/openapi.json (derived, RFC 9727 service-desc) ===\033[0m\n"

assert "api-catalog advertises it as a service-desc" \
  "$(echo "$apc" | jq -r '[.linkset[0].item[] | select(.rel == "service-desc") | .href] | map(endswith("/kiosk/openapi.json")) | any')" \
  "true"

# STILL Bearer-gated — and it is now the ONLY surface that is, for a reason the
# rest of the fleet retired the same day. `GET /kiosk/schema` went public
# (T-094) and the api-catalog hyperlinks every verb (T-093), so this document
# describes nothing an anonymous caller cannot already read. Phil was not asked
# about THIS endpoint, so rule 2 applies: it is filed as K-804 and the gate
# stays until it is answered. This assertion is what stops it drifting open by
# accident.
oa_anon=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/openapi.json")
assert "unauthenticated → 401"      "$oa_anon" "401"

oa_headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/openapi.json" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
oa=$(curl -sf "$SERVER_URL/kiosk/openapi.json" -H "Authorization: Bearer $ALICE_AGENT_TOKEN")

assert "served as an OpenAPI document" \
  "$(echo "$oa_headers" | grep -i '^Content-Type:' | grep -ic 'application/vnd.oai.openapi+json')" "1"
assert "declares OpenAPI 3.1"        "$(echo "$oa" | jq -r '.openapi')" "3.1.0"
assert "server is this origin's endpoint" \
  "$(echo "$oa" | jq -r '.servers[0].url')" "$SERVER_URL/kiosk"

# DERIVED, and this is the assertion that says so: the operator paths are
# exactly the verbs the canonical catalog publishes, with the query half at GET
# and the action half at POST. `/schema` and `/pay` are the wire's OWN reserved
# endpoints — the protocol's, not the operator's — and joined the document at
# the cutover, when they left the 0.3 envelope.
schema_doc=$(curl -sf "$SERVER_URL/kiosk/schema")
assert "one path per verb the canonical catalog publishes" \
  "$(echo "$oa" | jq -r '.paths | keys_unsorted | map(ltrimstr("/")) | map(select(. != "schema" and . != "pay")) | sort | join(",")')" \
  "$(echo "$schema_doc" | jq -r '[.queries[].name, .actions[].name] | sort | join(",")')"
assert "a query is a GET"            "$(echo "$oa" | jq -r '.paths."/salons" | keys | join(",")')" "get"
assert "an action is a POST"         "$(echo "$oa" | jq -r '.paths."/book_appointment" | keys | join(",")')" "post"
assert "the reserved /schema is described, as a GET" \
  "$(echo "$oa" | jq -r '.paths."/schema" | keys | join(",")')" "get"
assert "…tagged wire, not queries"   "$(echo "$oa" | jq -r '.paths."/schema".get.tags | join(",")')" "wire"
# `/pay` is described because THIS origin serves it — it wires a payment
# provider, so `pay` is in its capabilities. The renderer gates both reserved
# paths on the live capability set, so the document describes what this origin
# ANSWERS rather than what the protocol allows in general. (The absent case is
# pinned by kiosk-server's own unit spec, which can register an origin without
# a provider; this harness only ever boots one fixture app.)
assert "the reserved /pay is described, as a POST" \
  "$(echo "$oa" | jq -r '.paths."/pay" | keys | join(",")')" "post"
assert "…also tagged wire"           "$(echo "$oa" | jq -r '.paths."/pay".post.tags | join(",")')" "wire"
assert "pay's capability is advertised" \
  "$(echo "$wk" | jq -r '.kiosk.capabilities | index("pay") != null')" "true"
assert "…and no /query or /run, ever again" \
  "$(echo "$oa" | jq -r '.paths | has("/query") or has("/run")')" "false"

# The verb's prose semantics travel VERBATIM — ADR-0021 stays the authority on
# meaning, and ADR-0024 narrows it rather than reversing it.
assert "the descriptor's description travels verbatim" \
  "$(echo "$oa" | jq -r '.paths."/salons".get.description')" \
  "$(echo "$schema_doc" | jq -r '.queries[] | select(.name == "salons") | .description')"

# `style` and `explode` EXPLICIT on every parameter (Prism ignores the
# defaults), and `limit`/`cursor` INJECTED because no input_schema declares
# them (a strict validator 400s the pagination the contract invites).
assert "every parameter writes style and explode" \
  "$(echo "$oa" | jq -r '[.paths[][] | .parameters // [] | .[] | select(has("$ref") | not)] | map(has("style") and has("explode")) | all')" \
  "true"
assert "limit and cursor are injected into a query" \
  "$(echo "$oa" | jq -r '[.paths."/salons".get.parameters[]."$ref"] | join(",")')" \
  "#/components/parameters/limit,#/components/parameters/cursor"
assert "the reserved parameters are form/explode:true" \
  "$(echo "$oa" | jq -r '[.components.parameters[] | .style == "form" and .explode == true] | all')" "true"
assert "an action gets no query parameters" \
  "$(echo "$oa" | jq -r '.paths."/book_appointment".post | has("parameters")')" "false"

# The closed error vocabulary is the `code` enum, and 405 is deliberately not
# a response of a declared operation — it is what the OTHER method answers.
assert "the code enum is the closed vocabulary" \
  "$(echo "$oa" | jq -r '.components.schemas.Problem.properties.code.enum | length')" "15"
assert "problems are application/problem+json" \
  "$(echo "$oa" | jq -r '.components.responses.problem404.content | keys | join(",")')" \
  "application/problem+json"
assert "405 is not a declared response" \
  "$(echo "$oa" | jq -r '.paths."/salons".get.responses | has("405")')" "false"

# ─── Kiosk-* response headers ───────────────────────────────────────────

printf "\n\033[1m=== response headers ===\033[0m\n"

headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/salons" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
  -H "Accept: application/json")

assert "Kiosk-Server-Version present" "$(echo "$headers" | grep -i '^Kiosk-Server-Version:' | wc -l | tr -d ' ')" "1"
assert "Kiosk-API-Version present"    "$(echo "$headers" | grep -i '^Kiosk-API-Version:'    | wc -l | tr -d ' ')" "1"
assert "Kiosk-Min-Client present"     "$(echo "$headers" | grep -i '^Kiosk-Min-Client:'     | wc -l | tr -d ' ')" "1"

# ─── a query is a GET at its own path ───────────────────────────────────

printf "\n\033[1m=== GET /kiosk/salons ===\033[0m\n"

# The answer IS the handler's payload — `render json: Salon.all` reaches the
# assistant as a bare JSON array, with no `ok`/`kind` wrapper to unpick.
r=$(query_call "$ALICE_AGENT_TOKEN" "salons")
assert "the body is a bare array"  "$(echo "$r" | jq -r 'type')"                   "array"
assert "no envelope wrapper"       "$(echo "$r" | jq -r 'if type == "object" then has("ok") else false end')" "false"
assert "exactly 1 salon"           "$(echo "$r" | jq -r 'length')"                 "1"
assert "salon name is Combette"      "$(echo "$r" | jq -r '.[0].name')"              "Combette on Park"

# Design §3.3 — the cache policy is response shape, so it is asserted here
# with the body. Without `Kiosk-PoW` in Vary a private cache keyed on the URL
# would serve a paid 200 to an unpaid retry.
cache_headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/salons" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
assert "Vary names both request headers" \
  "$(echo "$cache_headers" | grep -ic '^Vary: Authorization, Kiosk-PoW')" "1"
assert "a 200 defaults to private, no-store" \
  "$(echo "$cache_headers" | grep -ic '^Cache-Control: private, no-store')" "1"

# ─── GET /kiosk/schema — PUBLIC, AND THE ONE EXCEPTION TO THE LINE ABOVE ───
#
# T-094. The two assertions above are the fleet-wide policy: every wire
# response is identity-scoped, so it varies on `Authorization` and is never
# stored by a shared cache. `schema` is the ONE endpoint under the mount that
# is none of those things — no identity, no toll, the same bytes for everyone,
# derived once at boot — so it gets the opposite policy, and BOTH halves are
# asserted here because getting only one right is worse than neither: `public`
# with a `Vary: Authorization` is a document no CDN will ever reuse.

printf "\n\033[1m=== GET /kiosk/schema (public, cacheable) ===\033[0m\n"

sch_status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/schema")
sch_headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/schema")
assert "no Authorization header → 200"  "$sch_status" "200"
assert "…served public, short TTL"      "$(echo "$sch_headers" | grep -ic '^Cache-Control: max-age=300, public')" "1"
assert "…with a STRONG ETag (no W/)"    "$(echo "$sch_headers" | tr -d '\r' | grep -Eci '^ETag: "[0-9a-f]{32}"$')" "1"
# NOT EVEN `Vary: Accept`, which Rails stamps on any negotiated render: this
# endpoint answers application/json to every caller, so a Vary of any kind
# splits a CDN's cache for a variance that does not exist.
assert "…and NO Vary at all"            "$(echo "$sch_headers" | grep -ic '^Vary:')" "0"
assert "…and never a 402: the toll went with the gate" \
  "$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/schema")" "200"

# THE CACHE-BUSTING SHAPE. The digest-versioned URL — the one the discovery
# documents publish — is immutable for a year; the bare path is not, because
# its bytes change under a fixed URL. Same document either way.
sch_digest=$(echo "$wk" | jq -r '.kiosk.schema_url' | sed 's/.*v=//')
sch_v_headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/schema?v=$sch_digest")
assert "?v=<digest> is immutable for a year" \
  "$(echo "$sch_v_headers" | grep -ic '^Cache-Control: max-age=31536000, public, immutable')" "1"
assert "…and the boot digest IS the ETag" \
  "$(echo "$sch_headers" | tr -d '\r' | grep -i '^ETag:' | sed 's/.*"\(.*\)"/\1/')" "$sch_digest"
assert "…a stale ?v= still answers the CURRENT catalogue, short-lived" \
  "$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/schema?v=deadbeef" | grep -ic '^Cache-Control: max-age=300, public')" "1"
assert "If-None-Match on the digest → 304" \
  "$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/schema" -H "If-None-Match: \"$sch_digest\"")" "304"

# `limit` and `cursor` are RESERVED parameter names (T-070 rule 7): always
# accepted, never declared. `salons` declares the CLOSED empty object
# `{additionalProperties: false, properties: {}}`, so without the reserved
# rule this is exactly the request that would 400 as a disallowed additional
# property — on the very verbs the pagination contract invites it on.
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/salons?limit=5&cursor=eyJvIjoyMH0" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
assert "reserved limit/cursor accepted → 200" "$status" "200"

# The contrast that keeps the assertion above honest: this origin runs with
# `validate_requests = true`, so `salons`'s closed schema DOES refuse an
# undeclared parameter. `limit` is accepted because it is reserved, not
# because nothing is checking.
r=$(query_call "$ALICE_AGENT_TOKEN" "salons" "nope=1")
assert "an undeclared parameter → bad_request"  "$(echo "$r" | jq -r '.code')" "bad_request"
assert "…and the refusal names it"              "$(echo "$r" | jq -r '.detail | test("nope")')" "true"

# ─── an action is a POST at its own path ────────────────────────────────

printf "\n\033[1m=== POST /kiosk/book_appointment ===\033[0m\n"

# Get salon id first.
salon_id=$(query_call "$ALICE_AGENT_TOKEN" "salons" | jq -r '.[0].id')

r=$(action_call "$ALICE_AGENT_TOKEN" "book_appointment" "{\"salon_id\":$salon_id,\"slot\":\"2026-06-15T14:00:00Z\"}")
assert "the body is the action's object" "$(echo "$r" | jq -r 'type')"            "object"
assert "no envelope wrapper"       "$(echo "$r" | jq -r 'has("value")')"           "false"
assert "appointment_id returned"   "$(echo "$r" | jq -r '.appointment_id | length > 0')" "true"
assert "salon_id echoed"           "$(echo "$r" | jq -r '.salon_id')"              "$salon_id"
alice_appt_id=$(echo "$r" | jq -r '.appointment_id')

# Bob books at the same (public) salon so both users own exactly one row.
r=$(action_call "$BOB_AGENT_TOKEN" "book_appointment" "{\"salon_id\":$salon_id,\"slot\":\"2026-06-16T10:00:00Z\"}")
assert "bob: booked"               "$(echo "$r" | jq -r '.appointment_id | length > 0')" "true"
bob_appt_id=$(echo "$r" | jq -r '.appointment_id')

# The HTTP method carries the read/write semantics, so getting them the wrong
# way round is a 405: the resource EXISTS and refuses this method. RFC 9110
# §15.5.6 makes `Allow` mandatory on one, and the hint names the call to make.
mna_headers=$(curl -sS -o /tmp/mna_body -D - "$SERVER_URL/kiosk/book_appointment" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/book_appointment" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
r=$(cat /tmp/mna_body)
assert "GET at an action's path → 405"  "$status" "405"
assert "…carrying Allow: POST"          "$(echo "$mna_headers" | grep -ic '^Allow: POST')" "1"
assert "…as a problem document"         "$(echo "$mna_headers" | grep -ic '^Content-Type: application/problem+json')" "1"
assert "…code method_not_allowed"       "$(echo "$r" | jq -r '.code')" "method_not_allowed"
assert "…type names the same code"      "$(echo "$r" | jq -r '.type')" "https://kiosk.tech/problems/method_not_allowed"
assert "…and says it is an action"      "$(echo "$r" | jq -r '.detail | test("is an action")')" "true"

status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/salons" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" -H "Content-Type: application/json" -d '{}')
assert "POST at a query's path → 405"   "$status" "405"
mna2=$(curl -sS -o /dev/null -D - -X POST "$SERVER_URL/kiosk/salons" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" -H "Content-Type: application/json" -d '{}')
assert "…carrying Allow: GET"           "$(echo "$mna2" | grep -ic '^Allow: GET')" "1"

# ─── app-layer per-user isolation (the headline security property) ──────
# my_appointments filters WHERE user_id = kiosk.current_user_id(), where the
# GUC is set from the caller's authenticated identity (bearer token). With
# Alice AND Bob each owning one appointment, prove each principal sees ONLY
# their own row — never the other's — even though both hit the same query.

printf "\n\033[1m=== verify appointment landed + per-user isolation ===\033[0m\n"

alice_appts=$(query_call "$ALICE_AGENT_TOKEN" "my_appointments")
assert "alice: 1 appointment exists"  "$(echo "$alice_appts" | jq -r 'length')"                                 "1"
assert "alice: sees her own row"      "$(echo "$alice_appts" | jq -r --arg id "$alice_appt_id" '[.[].id] | index($id) != null')" "true"
assert "alice: does NOT see bob's row" "$(echo "$alice_appts" | jq -r --arg id "$bob_appt_id"   '[.[].id] | index($id) == null')" "true"

bob_appts=$(query_call "$BOB_AGENT_TOKEN" "my_appointments")
assert "bob: 1 appointment exists"    "$(echo "$bob_appts" | jq -r 'length')"                                   "1"
assert "bob: sees his own row"        "$(echo "$bob_appts" | jq -r --arg id "$bob_appt_id"   '[.[].id] | index($id) != null')" "true"
assert "bob: does NOT see alice's row" "$(echo "$bob_appts" | jq -r --arg id "$alice_appt_id" '[.[].id] | index($id) == null')" "true"

# ─── problem documents (RFC 9457) ───────────────────────────────────────

printf "\n\033[1m=== problem documents ===\033[0m\n"

# Unknown query name → 404, problem type + code not_found
nf_headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/frobnicate" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/frobnicate" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
assert "unknown query → 404"        "$status" "404"
assert "served as problem+json"     "$(echo "$nf_headers" | grep -ic '^Content-Type: application/problem+json')" "1"
assert "an error is never cached"   "$(echo "$nf_headers" | grep -ic '^Cache-Control: private, no-store')" "1"

r=$(query_call "$ALICE_AGENT_TOKEN" "frobnicate")
assert "type names the code"        "$(echo "$r" | jq -r '.type')"   "https://kiosk.tech/problems/not_found"
assert "title is the code's, not the incident's" "$(echo "$r" | jq -r '.title')" "Not found"
assert "status restates the HTTP status"         "$(echo "$r" | jq -r '.status')" "404"
assert "code is the branch point"   "$(echo "$r" | jq -r '.code')"   "not_found"
assert "hint names a real query"    "$(echo "$r" | jq -r '.hint | test("salons")')" "true"
assert "no ok field survives"       "$(echo "$r" | jq -r 'has("ok")')" "false"

# Unknown action name → NotFound, http 404, code not_found
status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/nope" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}')
assert "unknown action → 404"      "$status" "404"

# Missing Authorization → Unauthenticated, http 401. Note this holds for a
# name that does NOT exist too: the wire authenticates before it will say
# whether a verb is registered, so an unauthenticated probe cannot enumerate
# the catalog one path at a time.
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/salons")
assert "no auth → 401"             "$status" "401"
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/frobnicate")
assert "no auth on an unknown name → 401 (no enumeration)" "$status" "401"

# Stub IdP returns nil for unknown token shape → 401
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/salons" \
  -H "Authorization: Bearer garbage")
assert "garbage token → 401"       "$status" "401"

# A path that cannot be a verb name never reaches the wire at all — the route
# constraint leaves it a plain routing 404.
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/Salons")
assert "a non-verb-shaped path → 404" "$status" "404"

# ─── the 0.3 wire is GONE (T-074 = A) ───────────────────────────────────
#
# A hard cut: no route, no tombstone, no 404 hint payload naming the retired
# endpoints, no second conformance surface. `POST /kiosk/query` now reaches the
# PER-VERB controller as a verb literally named `query`, which nobody
# registered — so it answers the ordinary `not_found`, exactly as any other
# unregistered name does. That is the assertion: not that the old endpoint is
# special-cased, but that it is not special at all.

printf "\n\033[1m=== the 0.3 wire is gone ===\033[0m\n"

for retired in query run; do
  body=$(curl -sS -X POST "$SERVER_URL/kiosk/$retired" \
           -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
           -H "Content-Type: application/json" -d '{"name":"salons"}')
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/$retired" \
           -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
           -H "Content-Type: application/json" -d '{"name":"salons"}')
  assert "POST /kiosk/$retired → 404"        "$code" "404"
  assert "…as an ordinary not_found"         "$(echo "$body" | jq -r '.code')" "not_found"
  assert "…with no 0.3 envelope residue"     "$(echo "$body" | jq -r 'has("ok") or has("error")')" "false"
done

# `schema` answers the payload VERBATIM now — it moved off the envelope with
# `pay` and the auth plane in the cutover wave — and it answers it to ANYONE.
old_schema=$(curl -sS "$SERVER_URL/kiosk/schema")
assert "GET /kiosk/schema is unenveloped"  "$(echo "$old_schema" | jq -r 'has("ok") or has("kind") or has("value")')" "false"
assert "…the catalog is the body itself"   "$(echo "$old_schema" | jq -r '.queries | length > 0')" "true"

# A GET at an action's path is 405 with `Allow`, never a silent 404 — the
# resource EXISTS, and an assistant that read 404 would give up on a verb it
# could have called correctly.
mna_code=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/book_appointment" \
             -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
mna_allow=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/book_appointment" \
              -H "Authorization: Bearer $ALICE_AGENT_TOKEN" | tr -d '\r' | awk 'tolower($1)=="allow:"{print $2}')
mna_body=$(curl -sS "$SERVER_URL/kiosk/book_appointment" -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
assert "GET an action → 405"               "$mna_code" "405"
assert "…carrying Allow: POST"             "$mna_allow" "POST"
assert "…coded method_not_allowed"         "$(echo "$mna_body" | jq -r '.code')" "method_not_allowed"

# T-095 / K-801: the catalog's `verbs` is GONE. It rendered
# `Array(config.capabilities)` — the same call `/.well-known/kiosk.json` makes
# for `capabilities` — so it was ONE value published under two names, and the
# beat that used to compare them could only ever pass. The module set has one
# home now, and this asserts the field did not come back.
assert "schema publishes {queries, actions} and nothing else" \
  "$(echo "$old_schema" | jq -r 'keys_unsorted | join(",")')" "queries,actions"
assert "…and the module set lives in kiosk.json alone" \
  "$(echo "$wk" | jq -r '.kiosk.capabilities | join(",")')" "schema,queries,actions,pay"

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
# the bundled numpy solver and re-POSTing the SAME body with the proof(s) in the
# `Kiosk-PoW` request header (ADR-0022 — never a body `pow` field) SUCCEEDS 201,
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
assert "register-pow: wire answered rows"      "$(echo "$reg_out" | jq -r '.wire_payload_is_array')"  "true"

# ─── no-human AP2 pay flow (register → intent → cart → payment mandate → pay → persist) ───
printf "\n\033[1m=== no-human register → mandate → pay ===\033[0m\n"

pay_out=$( cd "$APP_DIR" && SERVER_URL="$SERVER_URL" KIOSK_ISSUER="$KIOSK_ISSUER" \
             bundle exec ruby "$FIXTURES/pay_flow.rb" )

assert "pay: http 200"                "$(echo "$pay_out" | jq -r '.http_code')"                       "200"
# `pay` answers the settlement object VERBATIM since the cutover — no
# `ok`/`kind`/`value` wrapper to unwrap.
assert "pay: unenveloped"             "$(echo "$pay_out" | jq -r '.response | has("ok") or has("kind") or has("value")')" "false"
assert "pay: psp_reference present"   "$(echo "$pay_out" | jq -r '.response.psp_reference | length > 0')" "true"
assert "pay: settled 1599"            "$(echo "$pay_out" | jq -r '.response.settled_amount_cents')" "1599"
assert "pay: settlement_id"           "$(echo "$pay_out" | jq -r '.response.settlement_id | length > 0')" "true"

# The full AP2 trail landed in Postgres — one row each, no human anywhere.
assert "db: 1 intent_mandate"         "$(psql -X -d "$DB_NAME" -tAc 'SELECT COUNT(*) FROM kiosk.intent_mandates')"   "1"
assert "db: 1 cart_mandate"           "$(psql -X -d "$DB_NAME" -tAc 'SELECT COUNT(*) FROM kiosk.cart_mandates')"     "1"
assert "db: 1 payment_mandate"        "$(psql -X -d "$DB_NAME" -tAc 'SELECT COUNT(*) FROM kiosk.payment_mandates')"  "1"
assert "db: settlement amount 1599"   "$(psql -X -d "$DB_NAME" -tAc 'SELECT settled_amount_cents FROM kiosk.settlements LIMIT 1')" "1599"

# ─── summary ────────────────────────────────────────────────────────────

printf "\n\033[1m=== summary ===\033[0m\n"
printf "  pass: %s\n  fail: %s\n" "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ] || exit 1
