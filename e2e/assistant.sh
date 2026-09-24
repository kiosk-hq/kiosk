#!/usr/bin/env bash
# Mock AI assistant — exercises the Kiosk wire surface against a running
# kiosk-server. Executed as a bash subprocess by e2e/run.sh after server
# start (not sourced — it runs under its own `set -euo pipefail`).
#
# Asserts on responses from the REST wire surface: the per-verb endpoints
# (GET /kiosk/<query-name>, POST /kiosk/<action-name>), /kiosk/pay, and the
# two public catalogue documents (/kiosk/schema, /kiosk/openapi.json). A path
# under the mount that names NEITHER a verb the catalogue publishes NOR one of
# the wire's own reserved endpoints is asserted to answer the ordinary routing
# 404 — with a bearer and without one alike, since a routing miss is decided
# before any credential is read.
# Exits non-zero on any failure.
#
# ONE ANSWER SHAPE. Every
# endpoint answers the handler's payload VERBATIM on success — a query a BARE
# ARRAY whether or not it paginates, an action its own object — and an RFC 9457
# problem document on an error. A paginated page says so in an RFC 8288 `Link:
# …; rel="next"` HEADER, with `X-Total-Count` beside it, so there is no
# composite body shape left at all. There is no name-dispatch endpoint: a verb
# is addressed by its own path, and `schema` and `pay` answer the same shape as
# the per-verb wire.
#
# ONE AUTH SHAPE, WITH TWO DELIBERATE EXCEPTIONS. Everything under the mount is
# Bearer-gated except the two DESCRIPTIONS of this origin's wire —
# `GET /kiosk/schema` and `GET /kiosk/openapi.json` — which are
# public, untolled and cacheable, and are the same registry in two dresses.
#
# Env (all set by run.sh; the pay-flow + DB assertions dereference them
# under `set -u`, so all are required):
#   SERVER_URL   — e.g. http://127.0.0.1:3001
#   APP_DIR      — the generated Rails app dir (cwd for pay_flow.rb)
#   FIXTURES     — path to e2e/fixtures (locates pay_flow.rb)
#   DB_NAME      — Postgres database for the direct AP2-trail assertions
#   KIOSK_ISSUER — issuer/audience passed through to pay_flow.rb
#   ALICE_AGENT / ALICE_AGENT_TOKEN, BOB_AGENT / BOB_AGENT_TOKEN — the two
#                  agent principals, minted by the binding ceremony

set -euo pipefail

SERVER_URL="${SERVER_URL:-http://127.0.0.1:3001}"

# A scratch file is named UNIQUELY PER INVOCATION and is read back through the
# variable that names it, never through a pattern and never through a re-typed
# literal. A fixed `/tmp` path is shared with every process on the machine and
# survives between runs, so a `curl` that fails leaves the PREVIOUS run's body
# in place and the next line parses it as this run's answer — a clean-looking
# pass for a request that never happened.
AGENTS_TXT_BODY="/tmp/kiosk-e2e-agents-txt.$$"
trap 'rm -f "$AGENTS_TXT_BODY"' EXIT

ALICE="00000000-0000-0000-0000-000000000001"
BOB="00000000-0000-0000-0000-000000000002"

# The two agent principals this suite runs as. They are REAL kiosk-pop JWTs the
# booted origin issued: run.sh drives e2e/fixtures/bind_assistants.rb through
# the shipped ceremony (Equihash-tolled register -> the human's link code ->
# claim) and exports the results here.
#
# The agent id is a UUID by construction rather than by convention, because
# `/auth/register` minted it: `kiosk.agents.id`, every
# `kiosk.*_mandates.agent_id` and `kiosk.current_agent_id()` are all typed
# `uuid` in the canonical schema, so a caller cannot choose a shape the shipped
# tables cannot store.
ALICE_AGENT="${ALICE_AGENT:?run.sh must export ALICE_AGENT from the binding ceremony}"
BOB_AGENT="${BOB_AGENT:?run.sh must export BOB_AGENT from the binding ceremony}"
ALICE_AGENT_TOKEN="${ALICE_AGENT_TOKEN:?run.sh must export ALICE_AGENT_TOKEN}"
BOB_AGENT_TOKEN="${BOB_AGENT_TOKEN:?run.sh must export BOB_AGENT_TOKEN}"

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
# `capabilities` names the MODULES this origin serves, not its verbs.
assert "kiosk.capabilities[]"      "$(echo "$wk" | jq -r '.kiosk.capabilities | join(",")')" "schema,queries,actions,pay"
# THE CACHE-BUSTED CATALOG LINK. This document is the SHORT-lived half of the
# pair: it expires in ONE MINUTE — the length of the post-deploy staleness
# window, not a load knob — and republishes the link,
# which is what lets the link itself be cached for a year.
assert "kiosk.schema_url is digest-versioned" \
  "$(echo "$wk" | jq -r '.kiosk.schema_url' | grep -Ec "^$SERVER_URL/kiosk/schema\?v=[0-9a-f]{32}\$")" "1"
assert "…and kiosk.json itself expires quickly" \
  "$(curl -sS -o /dev/null -D - "$SERVER_URL/.well-known/kiosk.json" | grep -ic '^Cache-Control: max-age=60, public')" "1"
# A public document that varies on anything is one a shared cache splits for
# nothing, and this one is public. Rails stamps
# `Vary: Accept` on a negotiated render, which is why the Accept header below
# is SENT rather than omitted: without it this assertion cannot fail.
assert "…and carries NO Vary, even when the request negotiates" \
  "$(curl -sS -o /dev/null -D - -H 'Accept: application/json' "$SERVER_URL/.well-known/kiosk.json" | grep -ic '^Vary:')" "0"

# THE FLEET OF PUBLIC DOCUMENTS, SPLIT IN TWO — and the split is the point.
#
# The api-catalog MUST name every verb. It is a static, untolled GET that
# anyone may read without authenticating, and an enumeration nobody has to ask
# for is not a defence worth keeping. The other four still must NOT name one —
# for a different reason, which is that they are POINTERS and not copies of the
# contract. Both halves are asserted POSITIVELY below; "no longer refuses to
# publish" would be a green nothing.
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
# THE TWO DESCRIPTIONS ARE LINKED AT `?v=<version>`: this document is a
# pointer with a one-minute TTL, so what it hands a reader is the url that may
# be cached for a year.
assert "…and links the catalog at its versioned url" \
  "$(echo "$apc_body" | jq -r '[.linkset[0].item[] | select(.rel == "service-desc") | .href] | map(test("\\?v=[0-9a-f]{32}$")) | all')" "true"
apc_headers=$(curl -sS -o /dev/null -D - -H 'Accept: application/json' "$SERVER_URL/.well-known/api-catalog")
assert "…served public, one minute" \
  "$(echo "$apc_headers" | grep -ic '^Cache-Control: max-age=60, public')" "1"
assert "…and carries NO Vary, even when the request negotiates" \
  "$(echo "$apc_headers" | grep -ic '^Vary:')" "0"

# ─── native discovery: agents.txt / agents.json / agent-configuration ───
#
# The agents.txt v1.0 surface (ROOT-served) plus the RFC 8414-style
# agent-configuration doc, all served by DiscoveryController from the same
# WellKnown model as kiosk.json above (so they cannot drift).

printf "\n\033[1m=== /agents.txt (native agents.txt v1.0) ===\033[0m\n"

# Capture status + headers + body in one request.
at_headers=$(curl -sS -o "$AGENTS_TXT_BODY" -D - "$SERVER_URL/agents.txt")
at_status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/agents.txt")
at_body=$(cat "$AGENTS_TXT_BODY")
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
# `capabilities` under `wire.verbs`.
assert "agents.json x-kiosk keys"    "$(echo "$aj" | jq -r '."x-kiosk" | keys_unsorted | join(",")')" "schema,api_catalog,mount_path,api_version"
# The pointer carries the boot digest as `?v=` — the cache-busting
# half, without which a year-long TTL on a fixed URL is a stale catalogue.
assert "agents.json x-kiosk.schema is digest-versioned" \
  "$(echo "$aj" | jq -r '."x-kiosk".schema' | grep -Ec '^/kiosk/schema\?v=[0-9a-f]{32}$')" "1"
assert "agents.json x-kiosk has no wire.verbs echo" "$(echo "$aj" | jq -r '."x-kiosk" | has("wire")')" "false"

printf "\n\033[1m=== /.well-known/agent-configuration (agent-auth discovery) ===\033[0m\n"

ac_status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/.well-known/agent-configuration")
ac=$(curl -sf "$SERVER_URL/.well-known/agent-configuration")
assert "agent-configuration → 200"        "$ac_status" "200"
assert "agent-configuration endpoints.register" "$(echo "$ac" | jq -r '.endpoints.register | length > 0')" "true"

# ─── /auth.md is not a cold-start dead end ───────────────────────────────
#
# An assistant that discovers through auth.md reads this file BEFORE it holds
# a token, learns from it that registration may be tolled, and then has to
# produce an Equihash proof. The solve is the one step of the handshake it
# cannot derive from prose, so the document has to hand over both halves: the
# wire skill (the instructions, carrying the solver's content-addressed pin)
# and the published solver itself. Asserted on the WIRE, over the served
# bytes, because that is where an assistant meets them.
printf "\n\033[1m=== /auth.md (cold-start pointers) ===\033[0m\n"

authmd_body=$(curl -sf "$SERVER_URL/auth.md")
assert "auth.md names the wire skill" \
  "$(printf '%s' "$authmd_body" | grep -c 'Wire skill for AI assistants: `https://kiosk.tech/skill-v')" "1"
assert "auth.md names the published solver" \
  "$(printf '%s' "$authmd_body" | grep -c 'https://kiosk.tech/pow/solve.py')" "1"
assert "auth.md forbids a hand-rolled solver" \
  "$(printf '%s' "$authmd_body" | grep -c 'Do not write your own Equihash solver')" "1"
# Non-vacuity control: this grep really is reading the served document.
assert "auth.md is really being read (control token)" \
  "$(printf '%s' "$authmd_body" | grep -c '^## Discover$')" "1"

printf "\n\033[1m=== /.well-known/api-catalog (RFC 9727 linkset) ===\033[0m\n"

apc_status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/.well-known/api-catalog")
apc_headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/.well-known/api-catalog")
apc=$(curl -sf "$SERVER_URL/.well-known/api-catalog")
assert "api-catalog → 200"           "$apc_status" "200"
assert "api-catalog Content-Type"    "$(echo "$apc_headers" | grep -i '^Content-Type:' | grep -ic 'application/linkset+json')" "1"
assert "api-catalog items non-empty" "$(echo "$apc" | jq -r '.linkset[0].item | length > 0')" "true"

# ─── the DERIVED OpenAPI document ───────────────────────────────────────
#
# A SECOND renderer over the registry `GET /kiosk/schema` renders. It is for
# TOOLING, it is named nowhere in skill.md, and it is PROVISIONAL — so what is
# asserted here is only that it is served, that it is gated exactly as the
# canonical catalog is, and that it says the four things a tooling generator
# measurably needs. Nothing in this harness may come to DEPEND on it.

printf "\n\033[1m=== GET /kiosk/openapi.json (derived, RFC 9727 service-desc) ===\033[0m\n"

# THE api-catalog LINKS IT AT ITS VERSIONED URL — this document is a
# pointer with a one-minute TTL, so the url it hands a reader is the one that
# may be cached for a year, not the bare path.
assert "api-catalog advertises it as a service-desc" \
  "$(echo "$apc" | jq -r '[.linkset[0].item[] | select(.rel == "service-desc") | .href] | map(test("/kiosk/openapi\\.json\\?v=[0-9a-f]{32}$")) | any')" \
  "true"

# PUBLIC AND UNTOLLED, on the same terms as `GET /kiosk/schema` and the
# api-catalog's per-verb links. An anonymous read does hand out the catalog
# enumeration, and that is deliberate: this document is the same registry in
# another dress, so withholding it protected nothing. There is no toll either,
# because a toll is charged against an identity this endpoint does not resolve.
oa_anon=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/openapi.json")
assert "no Authorization header → 200"  "$oa_anon" "200"

oa_headers=$(curl -sS -o /dev/null -D - -H 'Accept: application/json' "$SERVER_URL/kiosk/openapi.json")
oa=$(curl -sf "$SERVER_URL/kiosk/openapi.json")

assert "served as an OpenAPI document" \
  "$(echo "$oa_headers" | grep -i '^Content-Type:' | grep -ic 'application/vnd.oai.openapi+json')" "1"
# The same cache treatment `schema` gets, from the same seam. The Accept header
# above is sent deliberately: `Vary: Accept` is what Rails adds to a negotiated
# render, and it is invisible to a request that negotiates nothing.
assert "…public, one minute at the bare path" \
  "$(echo "$oa_headers" | grep -ic '^Cache-Control: max-age=60, public')" "1"
assert "…with a STRONG ETag (no W/)" \
  "$(echo "$oa_headers" | tr -d '\r' | grep -Eci '^ETag: "[0-9a-f]{32}"$')" "1"
assert "…and NO Vary at all"        "$(echo "$oa_headers" | grep -ic '^Vary:')" "0"
oa_etag=$(echo "$oa_headers" | tr -d '\r' | grep -i '^ETag:' | sed 's/.*"\(.*\)"/\1/')
assert "If-None-Match on its ETag → 304" \
  "$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/openapi.json" -H "If-None-Match: \"$oa_etag\"")" "304"
oa_v=$(echo "$apc" | jq -r '[.linkset[0].item[] | select(.rel == "service-desc") | .href] | map(select(test("openapi"))) | .[0]' | sed 's/.*v=//')
assert "?v=<version> is immutable for a year" \
  "$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/openapi.json?v=$oa_v" | grep -ic '^Cache-Control: max-age=31536000, public, immutable')" "1"
assert "declares OpenAPI 3.1"        "$(echo "$oa" | jq -r '.openapi')" "3.1.0"
assert "server is this origin's endpoint" \
  "$(echo "$oa" | jq -r '.servers[0].url')" "$SERVER_URL/kiosk"

# DERIVED, and this is the assertion that says so: the operator paths are
# exactly the verbs the canonical catalog publishes, with the query half at GET
# and the action half at POST. `/schema` and `/pay` are the wire's OWN reserved
# endpoints — the protocol's, not the operator's — which is why the comparison
# below subtracts them before matching the two documents.
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

# The verb's prose semantics travel VERBATIM: this renderer copies the
# descriptor's `description` and never paraphrases it.
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

# The two pagination facts are RESPONSE HEADERS (RFC 8288 `Link`,
# `X-Total-Count`), and OpenAPI declares a response header under
# `responses.<code>.headers` — never as a body property. A generator pointed at
# this document must emit a header read, not a field read.
assert "a query's 200 declares Link and X-Total-Count as HEADERS" \
  "$(echo "$oa" | jq -r '[.paths."/salons".get.responses."200".headers | keys[]] | join(",")')" \
  "Link,X-Total-Count"
assert "…by \$ref into components.headers" \
  "$(echo "$oa" | jq -r '.paths."/salons".get.responses."200".headers.Link."$ref"')" \
  "#/components/headers/Link"
assert "…and NOT as a body property" \
  "$(echo "$oa" | jq -r '.components.schemas."salons.response" | (.properties // {}) | has("Link")')" "false"
assert "an action declares no pagination headers" \
  "$(echo "$oa" | jq -r '.paths."/book_appointment".post.responses."200" | has("headers")')" "false"
assert "X-Total-Count is not dressed up as a standard" \
  "$(echo "$oa" | jq -r '.components.headers."X-Total-Count".description | test("DE-FACTO CONVENTION") and test("no RFC")')" "true"

# The closed error vocabulary is the `code` enum, and 405 is deliberately not
# a response of a declared operation — it is what the OTHER method answers.
assert "the code enum is the closed vocabulary" \
  "$(echo "$oa" | jq -r '.components.schemas.Problem.properties.code.enum | length')" "17"
# …and it carries `verb_not_found` and `module_not_served` BY NAME, not merely
# by count -- a count alone would pass a document that swapped one member for
# another.
assert "…including verb_not_found and module_not_served" \
  "$(echo "$oa" | jq -r '[.components.schemas.Problem.properties.code.enum[] | select(. == "verb_not_found" or . == "module_not_served")] | length')" "2"
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

# ON EVERY ROUTE UNDER THE MOUNT, AND ON THE ERROR HALF (spec §3.6).
#
# The three assertions above are the ones this harness had, and they covered
# ONE endpoint on ONE status. §3.6 binds the whole mount — the wire verbs, the
# auth plane, the binding plane, the KYC endpoint and the mount-relative JWKS —
# "on success and on error alike", and that is precisely the surface an agent
# uses the handshake on: a client that must decide whether it can speak to this
# origin at all reads the version off whatever response it happens to get
# first, which is very often a refusal.
#
# The reference is right BY CONSTRUCTION (HeadersMiddleware stamps every path
# under the mount, and the render seam stamps again), and by construction is
# not by test: nothing proved the middleware was actually mounted by the
# INSTALL GENERATOR in a real app, which is the one thing a unit test on
# synthetic paths cannot see.
#
# Each row is `METHOD PATH [BODY]`. The STATUS is deliberately not asserted —
# most of these are refusals, several are 4xx, and that is the point: the
# handshake is unconditional. Bodies are junk on purpose so the error half is
# what answers.
printf "\n  every route under the mount, success and error alike:\n"
mount_routes=$(cat <<'ROUTES'
GET /kiosk/schema
GET /kiosk/openapi.json
GET /kiosk/salons
GET /kiosk/no_such_verb
POST /kiosk/salons {}
POST /kiosk/book_appointment {}
POST /kiosk/pay {}
GET /kiosk/auth/challenge
POST /kiosk/auth/register {}
POST /kiosk/auth/login {}
POST /kiosk/auth/revoke {}
POST /kiosk/auth/link {}
POST /kiosk/auth/claim {}
POST /kiosk/auth/unlink {}
POST /kiosk/oauth/device_authorization {}
POST /kiosk/oauth/token {}
POST /kiosk/agents/kyc {}
GET /kiosk/auth/assistants
GET /kiosk/.well-known/jwks.json
ROUTES
)
#
# UNAUTHENTICATED on purpose, every one of them. Two reasons, and the first is
# that a probe loop must not have side effects: `POST /kiosk/auth/revoke` with
# ALICE's live token revokes her tokens, and every assertion after this block
# would then be testing a different agent than it thinks. The second is that a
# refusal is the response an agent most often reads the version handshake off,
# so an unauthenticated sweep IS the error half §3.6 names.
mount_missing=""
mount_checked=0
while read -r verb rpath rbody; do
  [ -z "$verb" ] && continue
  if [ "$verb" = "GET" ]; then
    h=$(curl -sS -o /dev/null -D - "$SERVER_URL$rpath")
  else
    h=$(curl -sS -o /dev/null -D - -X POST "$SERVER_URL$rpath" \
          -H "Content-Type: application/json" -d "${rbody:-\{\}}")
  fi
  rstatus=$(echo "$h" | head -1 | awk '{print $2}')
  mount_checked=$((mount_checked + 1))
  for hdr in Kiosk-Server-Version Kiosk-API-Version Kiosk-Min-Client; do
    if [ "$(echo "$h" | grep -ic "^$hdr:")" != "1" ]; then
      mount_missing="$mount_missing $verb$rpath(HTTP $rstatus):$hdr"
    fi
  done
done <<< "$mount_routes"
assert "all three version headers on all 19 mount routes" "$mount_missing" ""
# The loop's own control: a `while read` over an empty heredoc reports success
# for having checked nothing, which is the shape of vacuous pass this harness
# has already been bitten by.
assert "…and the route loop actually ran" "$mount_checked" "19"

# THE NEGATIVE HALF (§3.6, matrix SPEC-010): the ROOT-served discovery surfaces
# sit outside the mount and carry none of the three. It is also the control for
# the loop above — if `grep -ic` matched everything, or the middleware stamped
# the whole app, this line would fail.
root_h=$(curl -sS -o /dev/null -D - "$SERVER_URL/.well-known/kiosk.json")
assert "…while a ROOT discovery surface carries none of them" \
  "$(echo "$root_h" | grep -ic '^Kiosk-\(Server-Version\|API-Version\|Min-Client\):')" "0"

# ─── the responses RAILS composes, not Kiosk (§3.6) ─────────────────────
#
# The loop above walks routes an operator DREW; every one of them is answered
# by a Kiosk controller, which stamps the three headers at its own render seam
# even if the middleware never ran. The class of response it cannot reach is
# the one no Kiosk code touches: a routing 404 for a path under the mount that
# nobody drew, and an unhandled 500. Both are manufactured by
# `ActionDispatch::ShowExceptions` ABOVE the router, so the header middleware
# is APPENDED — i.e. innermost — which is what lets it stamp a response no
# Kiosk controller composed. Appended anywhere else and those two responses
# leave the origin bare: a `POST` to an undrawn route under the mount answers
# 404 with none of the three, while the same origin's `POST /kiosk/auth/login`
# 400 carries all of them.
#
# These four probes are the whole of it: the two exception responses UNDER the
# mount must carry all three, and the operator's own routes outside it — a
# working page and a broken one, so the same exception path is covered on both
# sides of the boundary — must carry none.
printf "\n  the responses Rails composes itself:\n"
kiosk_count() { echo "$1" | grep -ic '^Kiosk-\(Server-Version\|API-Version\|Min-Client\):'; }

r404_h=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/nope/nope")
assert "a routing 404 UNDER the mount is a 404" \
  "$(echo "$r404_h" | head -1 | awk '{print $2}')" "404"
assert "…and carries all three version headers" "$(kiosk_count "$r404_h")" "3"

r500_h=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/boom")
assert "an unhandled 500 UNDER the mount is a 500" \
  "$(echo "$r500_h" | head -1 | awk '{print $2}')" "500"
assert "…and carries all three version headers" "$(kiosk_count "$r500_h")" "3"

host_ok_h=$(curl -sS -o /dev/null -D - "$SERVER_URL/operator/health")
assert "the OPERATOR's own 200 outside the mount carries none" \
  "$(kiosk_count "$host_ok_h")" "0"

host_500_h=$(curl -sS -o /dev/null -D - "$SERVER_URL/operator/boom")
assert "…and neither does the operator's own 500 — same exception path" \
  "$(kiosk_count "$host_500_h")" "0"

# ─── the handshake VALUES, and the advisory that refuses nothing ────────
#
# Spec §3.6 (matrix SPEC-009): `Kiosk-API-Version` is the protocol version at
# MAJOR.MINOR.PATCH, `Kiosk-Server-Version` is implementation-defined and
# opaque, and `Kiosk-Min-Client` is ADVISORY — "no endpoint rejects on its
# basis". That last clause is a negative, and a negative about a header the
# protocol defines only as a RESPONSE: the honest way to test it is to send a
# client that announces itself as ancient, in every spelling an operator might
# be tempted to sniff, and prove it is served anyway.
api_version=$(echo "$headers" | tr -d '\r' | grep -i '^Kiosk-API-Version:' | awk '{print $2}')
min_client=$(echo "$headers"  | tr -d '\r' | grep -i '^Kiosk-Min-Client:'  | awk '{print $2}')
assert "Kiosk-API-Version is MAJOR.MINOR.PATCH" \
  "$(echo "$api_version" | grep -Ec '^[0-9]+\.[0-9]+\.[0-9]+$')" "1"
assert "Kiosk-Min-Client is a version, and it is advertised" \
  "$(echo "$min_client" | grep -Ec '^[0-9]+\.[0-9]+')" "1"
# The advisory negative. `Kiosk-Min-Client` is echoed back BELOW the advertised
# floor, and two plausible client-version spellings ride along; a serving
# origin answers 200 to all of it.
assert "an ancient client is SERVED, not refused — the floor is advisory" \
  "$(curl -sS -o /dev/null -w '%{http_code}' "$SERVER_URL/kiosk/salons" \
       -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
       -H "Kiosk-Min-Client: 0.0.1" \
       -H "Kiosk-Client-Version: 0.0.1" \
       -H "User-Agent: kiosk-agent/0.0.1")" "200"
# The control that keeps the line above from being "this endpoint answers 200
# to everything": the SAME request with a bad token is refused, so the 200 is
# a decision about this caller rather than an open door.
assert "…while the same request with a bad token is still 401" \
  "$(curl -sS -o /dev/null -w '%{http_code}' "$SERVER_URL/kiosk/salons" \
       -H "Authorization: Bearer garbage" \
       -H "Kiosk-Min-Client: 0.0.1")" "401"

# ─── a query is a GET at its own path ───────────────────────────────────

printf "\n\033[1m=== GET /kiosk/salons ===\033[0m\n"

# The answer IS the handler's payload — `render json: Salon.all` reaches the
# assistant as a bare JSON array, with no `ok`/`kind` wrapper to unpick.
r=$(query_call "$ALICE_AGENT_TOKEN" "salons")
assert "the body is a bare array"  "$(echo "$r" | jq -r 'type')"                   "array"
assert "no envelope wrapper"       "$(echo "$r" | jq -r 'if type == "object" then has("ok") else false end')" "false"
assert "exactly 1 salon"           "$(echo "$r" | jq -r 'length')"                 "1"
assert "salon name is Combette"      "$(echo "$r" | jq -r '.[0].name')"              "Combette on Park"

# Spec §3.7.1 — the cache policy is response shape, so it is asserted here
# with the body. Without `Kiosk-PoW` in Vary a private cache keyed on the URL
# would serve a paid 200 to an unpaid retry; without `Kiosk-Timezone` it would
# serve an answer computed for one caller's calendar day to a caller on another
# clock that sent the identical URL.
cache_headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/salons" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
assert "Vary names all three request headers" \
  "$(echo "$cache_headers" | grep -ic '^Vary: Authorization, Kiosk-PoW, Kiosk-Timezone')" "1"

# §3.7.4 (matrix SPEC-016), ON A BOOTED ORIGIN — "an operator MAY relax a 200
# to `private, max-age=N` for a payload that is genuinely identity-independent
# — a public catalogue, say". `salons` IS that catalogue and its handler now
# says so; the value reaches the wire because the dispatch seam preserves a
# handler's own response headers, so this line is the proof
# that a published permission is exercisable rather than decorative.
#
# The SPELLING is Rails': ActionDispatch parses `Cache-Control` and regenerates
# it on commit in its own directive order, so the handler's `private,
# max-age=60` leaves as `max-age=60, private`. Same directives; RFC 9111 gives
# their order no meaning.
assert "a handler MAY relax its own 200 (§3.7.4) — the public catalogue does" \
  "$(echo "$cache_headers" | grep -ic '^Cache-Control: max-age=60, private')" "1"
assert "…and never says public or s-maxage while doing it (§3.7.3)" \
  "$(echo "$cache_headers" | tr -d '\r' | grep -i '^Cache-Control:' | grep -Ec 'public|s-maxage')" "0"

# THE CONTROL, and it is the one that matters: a per-principal payload keeps
# the default. Without it "the wire honours a handler's Cache-Control" would
# pass just as well on a build that had stopped applying any policy at all.
mine_cache_headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/my_appointments" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
assert "…while an identity-scoped 200 keeps private, no-store" \
  "$(echo "$mine_cache_headers" | grep -ic '^Cache-Control: private, no-store')" "1"

# The pagination facts, on the wire rather than in the document. `salons` does
# not paginate,
# so its answer is COMPLETE: the wire states the matching total (which for a
# complete array is its own length) and sends NO `Link` at all — the link's
# absence is the only completeness signal an assistant may rely on.
assert "a COMPLETE answer carries X-Total-Count" \
  "$(echo "$cache_headers" | tr -d '\r' | grep -i '^X-Total-Count:' | awk '{print $2}')" "1"
assert "…and NO Link header, because there is no next page" \
  "$(echo "$cache_headers" | grep -ic '^Link:')" "0"

# ─── GET /kiosk/schema — PUBLIC, AND THE ONE EXCEPTION TO THE LINE ABOVE ───
#
# The two assertions above are the fleet-wide policy: every wire
# response is identity-scoped, so it varies on `Authorization` and is never
# stored by a shared cache. `schema` is one of TWO endpoints under the mount
# that are none of those things — no identity, no toll, the same bytes for
# everyone, derived once at boot (`openapi.json` is the other) — so it
# gets the opposite policy, and BOTH halves are asserted here because getting
# only one right is worse than neither: `public` with a `Vary: Authorization`
# is a document no CDN will ever reuse.

printf "\n\033[1m=== GET /kiosk/schema (public, cacheable) ===\033[0m\n"

sch_status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/schema")
# `Accept` is SENT on purpose: `Vary: Accept` is what Rails stamps on a
# negotiated render, so a probe that negotiates nothing cannot see the header
# the assertion below is about.
sch_headers=$(curl -sS -o /dev/null -D - -H 'Accept: application/json' "$SERVER_URL/kiosk/schema")
assert "no Authorization header → 200"  "$sch_status" "200"
assert "…served public, one minute"     "$(echo "$sch_headers" | grep -ic '^Cache-Control: max-age=60, public')" "1"
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
  "$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/schema?v=deadbeef" | grep -ic '^Cache-Control: max-age=60, public')" "1"
assert "If-None-Match on the digest → 304" \
  "$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/schema" -H "If-None-Match: \"$sch_digest\"")" "304"

# `limit` and `cursor` are RESERVED parameter names: always
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

# The HTTP method carries the read/write semantics, and this origin draws ONE
# route per verb with the method its kind requires — so getting them the wrong
# way round matches no route at all. Both directions answer the ordinary 404 any
# undrawn path gets, with no `Allow` and no problem document, and — the half that
# matters — the verb NEVER RUNS for the method it was not declared with. The
# catalogue at `GET /kiosk/schema` is where a caller learns which method to use.
mna_headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/book_appointment" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/book_appointment" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
appts_before_mna=$(psql -X -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM appointments")
assert "GET at an action's path → 404"  "$status" "404"
assert "…with no Allow on it"           "$(echo "$mna_headers" | grep -ic '^Allow:')" "0"
assert "…and no problem document"       "$(echo "$mna_headers" | grep -ic '^Content-Type: application/problem+json')" "0"
assert "…but still stamped by the wire" "$(echo "$mna_headers" | grep -ic '^Kiosk-Api-Version:')" "1"
assert "…and the write never ran"       "$(psql -X -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM appointments")" "$appts_before_mna"

status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/salons" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" -H "Content-Type: application/json" -d '{}')
assert "POST at a query's path → 404"   "$status" "404"
mna2=$(curl -sS -o /dev/null -D - -X POST "$SERVER_URL/kiosk/salons" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" -H "Content-Type: application/json" -d '{}')
assert "…carrying no Allow either"      "$(echo "$mna2" | grep -ic '^Allow:')" "0"

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

# ─── a name nobody registered: no route, so the ordinary 404 ────────────
#
# Every verb this origin serves has an explicit line in config/routes/kiosk.rb.
# A name that has no line matches no route, so the answer is the one the web
# framework composes for any unrouted path: no Kiosk problem document, no
# `code`, no hint. An assistant reads `GET /kiosk/schema` and dials a name that
# is in it -- it has no business at a path the catalogue never named.
#
# The §3.6 version headers are still stamped, because the middleware sits above
# the router, and that is the discriminating half of these assertions: the
# answer is Rails' own AND it is still identifiably this wire's origin.
nf_headers=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/frobnicate" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/frobnicate" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
assert "unknown query → 404"          "$status" "404"
assert "…not a problem document"      "$(echo "$nf_headers" | grep -ic '^Content-Type: application/problem+json')" "0"
assert "…still stamped by the wire"   "$(echo "$nf_headers" | grep -ic '^Kiosk-Api-Version:')" "1"

r=$(query_call "$ALICE_AGENT_TOKEN" "frobnicate")
assert "…with no code to branch on"   "$(echo "$r" | grep -c 'verb_not_found')" "0"

# Unknown action name → the same answer, the other method.
status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/nope" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}')
assert "unknown action → 404"         "$status" "404"

# ─── the refusal split: TWO codes an assistant can still meet here ──────
#
# `code` is the ONE field the spec tells an assistant to branch on, and three
# distinct situations can present as a 404-shaped miss. They carry three
# SEPARATE codes precisely so an assistant does not answer all three the same
# way: re-reading the catalogue and retrying is right for one of them, and for
# the others it is a wasted round trip plus a wrong report to the human. Two of
# the three are dialled at this BOOTED origin below, and the discriminating
# assertion is that they DIFFER.
#
# (1) verb_not_found -- the NAME is not a verb this origin registers. NOT
# dialable here, and that is a property of the ORIGIN rather than of the code:
# this app draws one explicit route per verb, so an unregistered name reaches no
# route at all and the answer is the plain 404 asserted just above -- Rails' own,
# with no `code` for an assistant to branch on. The code stays in the vocabulary
# for an operator who draws a catch-all action of their own, and the wire's
# answer for it is asserted in kiosk-server's own suite.

# (2) not_found -- the call is REAL and an ARGUMENT addressed something absent.
# Exercised in the BINDING block below, where `POST /kiosk/auth/login` for a key
# the origin no longer knows answers it through a real possession proof
# (§5.3, §9.1 rule 2). It cannot be dialled here: login proves possession BEFORE
# it looks the key up, so a probe with a made-up `signed` is answered 401 and
# never reaches the 404 this code names. Search "binding: login after unlink".

# (3) module_not_served -- the whole CAPABILITY is absent from this origin.
# This app configures no `kyc_public_key` (fixtures/initializer_kiosk.rb), so
# `POST /kiosk/agents/kyc` is a PUBLISHED path with no module behind it. 501,
# not 404: the URL is right. And not 403 either -- `forbidden` is
# identity-scoped, this refusal is origin-wide.
kyc_ms=$(curl -sS -X POST "$SERVER_URL/kiosk/agents/kyc" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
  -H "Content-Type: application/json" -d '{"kyc_jws":"not.a.jws"}')
kyc_ms_status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/agents/kyc" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
  -H "Content-Type: application/json" -d '{"kyc_jws":"not.a.jws"}')
assert "KYC at an origin that serves no KYC → 501" "$kyc_ms_status" "501"
assert "…code is module_not_served"  "$(echo "$kyc_ms" | jq -r '.code')" "module_not_served"
assert "…and NOT forbidden"          "$(echo "$kyc_ms" | jq -r '.code == "forbidden"')" "false"
assert "…type names the code"        "$(echo "$kyc_ms" | jq -r '.type')" "https://kiosk.tech/problems/module_not_served"
assert "…title is the code's, not the incident's" "$(echo "$kyc_ms" | jq -r '.title')" "Module not served"
assert "…status restates the HTTP status"         "$(echo "$kyc_ms" | jq -r '.status')" "501"
assert "…detail names the module"    "$(echo "$kyc_ms" | jq -r '.detail | test("KYC")')" "true"
assert "…and is itself an RFC 9457 document" \
  "$(curl -sS -o /dev/null -D - -X POST "$SERVER_URL/kiosk/agents/kyc" \
      -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
      -H "Content-Type: application/json" -d '{"kyc_jws":"not.a.jws"}' \
    | grep -ic '^Content-Type: application/problem+json')" "1"

# ONE HALF HERE: the unserved MODULE. Its partner -- the addressed-thing-absent
# `not_found` -- joins it at the binding block below, where the two samples are
# compared against each other.
KIOSK_T158_MODULE_CODE=$(echo "$kyc_ms" | jq -r .code)

# Missing Authorization → Unauthenticated, http 401 — on a path this origin
# actually draws. A name it does NOT draw is a routing miss, decided before any
# Kiosk code runs, so it answers 404 with or without a credential. That is not a
# disclosure: `GET /kiosk/schema` is public and publishes the whole catalogue to
# anyone who asks, which is why the 401-first order here is ordinary gate order
# and never was an anti-enumeration defence (§4.2).
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/salons")
assert "no auth → 401"             "$status" "401"
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/frobnicate")
assert "no auth on an unknown name → 404 (no route, no gate)" "$status" "404"

# An unrecognised credential resolves to no identity → 401.
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/salons" \
  -H "Authorization: Bearer garbage")
assert "garbage token → 401"       "$status" "401"

# A SELF-ASSERTED bearer, naming a seeded human and the `owner` role. It is not
# a token, it is a sentence: no parser anywhere reads this shape, in any
# environment, so it resolves to no identity like any other garbage.
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/salons" \
  -H "Authorization: Bearer agent:u-$ALICE:a-$ALICE_AGENT:r-owner")
assert "forged self-asserted bearer → 401" "$status" "401"

# A path that cannot be a verb name is the same plain routing 404 — nothing
# under the mount distinguishes it from a well-formed name nobody drew.
status=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/Salons")
assert "a non-verb-shaped path → 404" "$status" "404"

# ─── a path in neither the catalogue nor the reserved set → ordinary 404 ──
#
# TWO kinds of path are drawn under the mount and no third: the wire's OWN
# reserved endpoints — `schema`, `pay`, `openapi.json`, the auth plane, JWKS,
# KYC, the claim and link flows — and one explicit route per verb the
# catalogue publishes. This script dials both kinds and gets real answers —
# `/kiosk/schema`, a reserved name the catalogue does NOT publish, is dialed
# immediately after this block and answers 200. A name in NEITHER set is
# special-cased nowhere — no route, no tombstone, no 404 hint payload, no
# second conformance surface — so it is the ordinary routing 404 any undrawn
# path gets. `/kiosk/query` and `/kiosk/run` are two such names. That is the
# assertion — not that some path is handled specially, but that none is —
# with a bearer or without one, since a routing miss is decided before any
# credential is read.

printf "\n\033[1m=== paths in neither the catalogue nor the reserved set ===\033[0m\n"

for undrawn in query run; do
  body=$(curl -sS -X POST "$SERVER_URL/kiosk/$undrawn" \
           -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
           -H "Content-Type: application/json" -d '{"name":"salons"}')
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/$undrawn" \
           -H "Authorization: Bearer $ALICE_AGENT_TOKEN" \
           -H "Content-Type: application/json" -d '{"name":"salons"}')
  assert "POST /kiosk/$undrawn → 404"        "$code" "404"
  assert "…and the body is no envelope"      "$(echo "$body" | grep -c '\"ok\"')" "0"

  anon_code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/kiosk/$undrawn" \
           -H "Content-Type: application/json" -d '{"name":"salons"}')
  assert "POST /kiosk/$undrawn unauthenticated → 404 too" "$anon_code" "404"
done

# `schema` answers the payload VERBATIM — no `ok`/`kind`/`value` wrapper — and
# it answers it to ANYONE.
schema_body=$(curl -sS "$SERVER_URL/kiosk/schema")
assert "GET /kiosk/schema is unenveloped"  "$(echo "$schema_body" | jq -r 'has("ok") or has("kind") or has("value")')" "false"
assert "…the catalog is the body itself"   "$(echo "$schema_body" | jq -r '.queries | length > 0')" "true"

# A GET at an action's path draws no route here — this origin draws `POST
# /kiosk/book_appointment` and nothing else at that path — so it is the same
# ordinary 404 any undrawn path gets, with no `Allow`. The catalogue is what
# tells an assistant which method a verb takes: `book_appointment` is published
# as an action, and an assistant that read the schema dials POST.
mna_code=$(curl -sS -o /dev/null -w "%{http_code}" "$SERVER_URL/kiosk/book_appointment" \
             -H "Authorization: Bearer $ALICE_AGENT_TOKEN")
mna_allow=$(curl -sS -o /dev/null -D - "$SERVER_URL/kiosk/book_appointment" \
              -H "Authorization: Bearer $ALICE_AGENT_TOKEN" | tr -d '\r' | awk 'tolower($1)=="allow:"{print $2}')
assert "GET an action → 404"               "$mna_code" "404"
assert "…with no Allow header"             "$mna_allow" ""
assert "…and the catalogue says it is an action" \
  "$(echo "$schema_body" | jq -r '.actions | map(.name) | index("book_appointment") != null')" "true"

# THE MODULE SET HAS ONE HOME, and these assertions pin both halves of it.
# `/kiosk/schema` publishes `{queries, actions, events}` and nothing else; the
# modules this origin serves are published once, by `/.well-known/kiosk.json`. A
# second name for the same value would be a field two documents have to agree
# about, and a comparison between two renderings of one call can only ever pass.
assert "schema publishes {queries, actions, events} and nothing else" \
  "$(echo "$schema_body" | jq -r 'keys_unsorted | join(",")')" "queries,actions,events"
# AND THE THIRD ARRAY IS PRESENT WHILE THE MODULE IS NOT, which is the pair the
# spec asks for: `events` is REQUIRED and may be EMPTY, so a reader never has to
# branch on whether the member exists, while `capabilities` is where «does this
# origin serve the module at all» is answered — once. This origin declares no
# topic, so the array is empty and the capability is absent, and asserting both
# together is what would catch either half drifting to the other's answer.
assert "…the events array is present and EMPTY on an origin with no topics" \
  "$(echo "$schema_body" | jq -r '.events | length')" "0"
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
              HUMAN_USER_ID="$ALICE" HUMAN_EMAIL="alice@example.com" \
              HUMAN_PASSWORD="e2e-demo-password" \
              bundle exec ruby "$FIXTURES/claim_flow.rb" )

# THE ROLE IS NOT THE CALLER'S TO NAME.
# `role=customer` is the probe with teeth: `customer` is what THIS origin
# declares, and a declared value is the one an engine that trusted the caller
# would honour, while an undeclared one (`owner`) it would refuse anyway — so a
# harness probing only the invented role would pass straight over the
# escalation.
assert "binding: role/scope refused on the opening request" \
  "$(echo "$bind_out" | jq -r '.role_refused | join(" ")')" \
  "role=customer:400:invalid_request scope=customer:400:invalid_request role=owner:400:invalid_request json-role=customer:400:invalid_request"
assert "binding: device_authorization fields" "$(echo "$bind_out" | jq -r '.da_fields')"                            "true"
assert "binding: pending before approval"     "$(echo "$bind_out" | jq -r '.pending | map(tostring) | join(":")')"  "400:authorization_pending"
assert "binding: poll without proof denied"   "$(echo "$bind_out" | jq -r '.no_pop | map(tostring) | join(":")')"   "401:invalid_client"
assert "binding: human signed in (real Devise)" "$(echo "$bind_out" | jq -r '.signed_in')"                          "true"
assert "binding: human approve → 200"         "$(echo "$bind_out" | jq -r '.approve')"                              "200"
assert "binding: fast poll → slow_down"       "$(echo "$bind_out" | jq -r '.slow_down | map(tostring) | join(":")')" "400:slow_down"
assert "binding: token bound to the human"    "$(echo "$bind_out" | jq -r '.bound_user')"                           "true"
# The minted token carries the APPROVER's role — this origin's one declared
# role, resolved by kiosk-user-idp-devise from Alice's session — and not a value
# the unauthenticated opening request supplied.
assert "binding: token role is the approver's" "$(echo "$bind_out" | jq -r '.token_role')"                          "customer"
assert "binding: wire verb as bound account"  "$(echo "$bind_out" | jq -r '.wire_as_bound | map(tostring) | join(":")')" "200:true"
assert "binding: kiosk-pop login refresh"     "$(echo "$bind_out" | jq -r '.login_bound')"                          "200"
assert "binding: link-code mint (session)"    "$(echo "$bind_out" | jq -r '.link_mint')"                            "201"
assert "binding: link-code redeem → human"    "$(echo "$bind_out" | jq -r '.link_claim | map(tostring) | join(":")')" "201:true"
# 204, not 200: unlink answers with no body at all, and protocol.md §6.2 states
# that beside its two siblings.
assert "binding: unlink → 204 (no body)"      "$(echo "$bind_out" | jq -r '.unlink')"                               "204"
# THE TOKEN half of the unlink promise, including a token minted in the same
# wall-clock second as the unlink, which the watermark has to kill too.
assert "binding: held token dies at unlink"   "$(echo "$bind_out" | jq -r '.held_token_after_unlink')"        "401"
assert "binding: same-second token dies too"  "$(echo "$bind_out" | jq -r '.same_second_token_after_unlink')" "401"
assert "binding: login after unlink → 404"    "$(echo "$bind_out" | jq -r '.login_after_unlink')"                   "404"
# THE OTHER LIVE LEG of the split. The key was real, the proof was real, and
# the thing
# the call ADDRESSED is gone -- spec §9.1 rule 2. So the code is `not_found`,
# and it is specifically NOT `module_not_served`: this origin serves the auth
# module, and `auth/login` is a verb it very much has.
assert "binding: …and the code is not_found"  "$(echo "$bind_out" | jq -r '.login_after_unlink_code')"              "not_found"
assert "binding: …type names it"              "$(echo "$bind_out" | jq -r '.login_after_unlink_type')"              "https://kiosk.tech/problems/not_found"

# THE DISCRIMINATOR, and the point of the split. Two situations that could
# share one code, dialled at this booted origin, must answer with TWO
# DIFFERENT codes. A harness that only asserted "some refusal" would pass a
# single-code wire; this line would not. (The third
# situation, an unregistered verb NAME, is not dialable at an origin that draws
# one explicit route per verb -- it is the plain routing 404 asserted far above.)
assert "the two 'it is not here' answers are two DIFFERENT codes" \
  "$(printf '%s\n%s\n' \
      "$(echo "$bind_out" | jq -r '.login_after_unlink_code')" \
      "$KIOSK_T158_MODULE_CODE" | sort -u | wc -l | tr -d ' ')" "2"

# ─── register-PoW golden path (402 pow_required → solve Equihash → 201) ──────
#
# The DoD-2 leg: the agent golden path registers through a REAL register-time
# Equihash proof-of-work, not a toll-free shortcut. HOW MANY proofs and HOW BIG
# is the app's configuration — `registration_pow_count` and
# `E2E_REGISTRATION_POW_PARAMS`, both in fixtures/initializer_kiosk.rb — and
# this comment does not restate either: a number typed here, in the fixture
# that sets it, and in the register helper is three hand-kept copies, and one
# edit to the constant leaves two of them describing a toll the server does
# not charge. The count is asserted from the WIRE by the "1 challenge
# issued" check below — `challenges_len`, read off the 402 the server actually
# answered with — which is where a number in this file belongs.
# register_pow_flow.rb proves, in one run: (1) a no-proof register is
# REJECTED 402 pow_required with challenges[], (2) solving each challenge with
# the bundled numpy solver and re-POSTing the SAME body with the proof(s) in the
# `Kiosk-PoW` request header — never a body `pow` field — SUCCEEDS 201,
# (3) the PoW-minted token authenticates a real wire verb. Same mechanism the
# demos use (kiosk-demo-skooti).
printf "\n\033[1m=== register-PoW golden path: no-proof 402 → solve Equihash → 201 → wire ===\033[0m\n"

reg_out=$( cd "$APP_DIR" && SERVER_URL="$SERVER_URL" KIOSK_ISSUER="$KIOSK_ISSUER" \
             POW_CAPTURE="${POW_CAPTURE:-}" \
             bundle exec ruby "$FIXTURES/register_pow_flow.rb" )

assert "register-pow: no-proof → 402"          "$(echo "$reg_out" | jq -r '.no_proof_status')"        "402"
assert "register-pow: code pow_required"       "$(echo "$reg_out" | jq -r '.no_proof_code')"          "pow_required"
assert "register-pow: 1 challenge issued"      "$(echo "$reg_out" | jq -r '.challenges_len')"         "1"

# ─── HOW BIG the toll is, asserted off the wire ──────────────────────────────
#
# The count above is read off the 402, and so is the SIZE. A comment stating
# the register toll's (n, k) is true only until somebody retunes it and cannot
# notice when they do, so the server has to say it instead:
# `challenge_params_nk` is `challenges[0].params`
# joined `n:k`, off the same 402 the count comes from.
#
# THE EXPECTED PAIR IS READ, NOT TYPED. Typing `96:5` here would put a fourth
# hand-kept copy of the constant in this file, and this assertion
# would then hold two hand edits in agreement rather than the server to its own
# configuration. It is extracted from the initializer that CONFIGURES the gate,
# so what is proven is that the origin publishes the toll this harness asked for
# — which a config read cannot show, because it never leaves the config.
reg_pow_expected=$(
  sed -n 's/^E2E_REGISTRATION_POW_PARAMS[[:space:]]*=[[:space:]]*{[[:space:]]*n:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*,[[:space:]]*k:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*}.*/\1:\2/p' \
      "$FIXTURES/initializer_kiosk.rb"
)
# The vacuity arm, and it guards the READING rather than the comparison: if the
# constant is renamed, reformatted or deleted, `sed` prints nothing and the
# comparison below would hold "" against "" the moment the server also stopped
# publishing params. This fails first, and says which half broke.
assert "register-pow: the expected (n,k) was READ from the initializer" \
       "$(printf '%s' "$reg_pow_expected" | grep -cE '^[0-9]+:[0-9]+$')"                             "1"
assert "register-pow: served (n,k) IS the configured pair" \
       "$(echo "$reg_out" | jq -r '.challenge_params_nk')"    "$reg_pow_expected"
assert "register-pow: solve+proof → registered" "$(echo "$reg_out" | jq -r '.with_proof_registered')" "true"
assert "register-pow: role pinned customer"    "$(echo "$reg_out" | jq -r '.role')"                   "customer"
assert "register-pow: minted token wire → 200" "$(echo "$reg_out" | jq -r '.wire_status')"            "200"
assert "register-pow: wire answered rows"      "$(echo "$reg_out" | jq -r '.wire_payload_is_array')"  "true"

# ─── no-human AP2 pay flow (register → intent → cart → payment mandate → pay → persist) ───
printf "\n\033[1m=== no-human register → mandate → pay ===\033[0m\n"

pay_out=$( cd "$APP_DIR" && SERVER_URL="$SERVER_URL" KIOSK_ISSUER="$KIOSK_ISSUER" \
             PAY_CAPTURE="${PAY_CAPTURE:-}" \
             bundle exec ruby "$FIXTURES/pay_flow.rb" )

assert "pay: http 200"                "$(echo "$pay_out" | jq -r '.http_code')"                       "200"
# `pay` answers the settlement object VERBATIM — no `ok`/`kind`/`value`
# wrapper to unwrap.
assert "pay: unenveloped"             "$(echo "$pay_out" | jq -r '.response | has("ok") or has("kind") or has("value")')" "false"
assert "pay: psp_reference present"   "$(echo "$pay_out" | jq -r '.response.psp_reference | length > 0')" "true"
assert "pay: settled 1599"            "$(echo "$pay_out" | jq -r '.response.settled_amount_cents')" "1599"
assert "pay: settlement_id"           "$(echo "$pay_out" | jq -r '.response.settlement_id | length > 0')" "true"

# The full AP2 trail landed in Postgres — one row each, no human anywhere.
assert "db: 1 intent_mandate"         "$(psql -X -d "$DB_NAME" -tAc 'SELECT COUNT(*) FROM kiosk.intent_mandates')"   "1"
assert "db: 1 cart_mandate"           "$(psql -X -d "$DB_NAME" -tAc 'SELECT COUNT(*) FROM kiosk.cart_mandates')"     "1"
assert "db: 1 payment_mandate"        "$(psql -X -d "$DB_NAME" -tAc 'SELECT COUNT(*) FROM kiosk.payment_mandates')"  "1"
assert "db: settlement amount 1599"   "$(psql -X -d "$DB_NAME" -tAc 'SELECT settled_amount_cents FROM kiosk.settlements LIMIT 1')" "1599"

# ─── the audit sink, read back off a booted origin ──────────────────────
#
# Kiosk STORES no audit trail — it OFFERS one. `c.audit_sink` is a callable the
# operator sets, and this origin's is DemoAuditSink (app/services/demo_audit_sink.rb),
# which appends one JSON line per action invocation to $AUDIT_EVENTS. The
# assertions below read that trail back off the booted origin, and three of
# them are what an OFFERED trail specifically needs: the arguments arrive IN
# FULL, a sink that RAISES does not fail the action, and the canonical
# migration set creates no log table of its own.

printf "\n\033[1m=== the audit sink (c.audit_sink) ===\033[0m\n"

# One line per event; `jq -s` slurps the file into an array so a filter can
# count. An absent file (nothing ever emitted) reads as an empty array.
events() { [ -s "$AUDIT_EVENTS" ] && jq -s "$1" "$AUDIT_EVENTS" || echo "0"; }
event_count() { events "[.[] | select($1)] | length"; }

# 1. The successful bookings above each emitted one event, with the identity the
#    token carried and the outcome the wire reported.
assert "audit: the two bookings emitted ok events" \
  "$(event_count '.action == "book_appointment" and .status == "ok"')" "2"
assert "audit: the event names the acting assistant, its role and its actor" \
  "$(event_count ".agent_id == \"$ALICE_AGENT\" and .actor == \"agent\" and .role == \"customer\"")" "1"

# 2. The invocation's own timestamp travels with it — not the sink's clock.
assert "audit: the event carries the invocation timestamp" \
  "$(events '[.[] | select(.invoked_at | test("^20[0-9][0-9]-"))] | length > 0')" "true"

# 3. THE ARGUMENTS ARRIVE IN FULL. This is the whole point of the reversal: the
#    slot the assistant actually sent is IN the event, unredacted, because Kiosk
#    does not decide on an operator's behalf what their retention policy is.
assert "audit: the arguments arrive IN FULL — values included" \
  "$(event_count '.args.slot == "2026-06-15T14:00:00Z" and (.args.salon_id | type) == "number"')" "1"

# 4. …AND REDACTING IS ONE CALL AT THE SEAM. The same events, written a second
#    time through `event.with_arg_types`: argument names kept, every value
#    replaced by its JSON type, nothing of the payload left.
assert "audit: …and event.with_arg_types withholds them in one call" \
  "$(jq -s '[.[] | select(.args.salon_id == "integer" and .args.slot == "string")] | length > 0' "$AUDIT_EVENTS_REDACTED")" "true"
assert "audit: …so the redacted copy carries no value that was sent" \
  "$(grep -c '2026-06-15T14:00:00Z' "$AUDIT_EVENTS_REDACTED" || true)" "0"

# 5. A QUERY EMITS NOTHING. This is an ACTION trail; the many reads this harness
#    has already made must have left it alone.
assert "audit: queries emit nothing" \
  "$(event_count '.action == "salons" or .action == "my_appointments"')" "0"

# 6. THE FAILURE BRANCH. A booking for a salon that does not exist reaches the
#    handler and raises; the action's own transaction ROLLS BACK and the event
#    must be emitted anyway — which is why the seam sits outside the transaction.
before_fail=$(event_count '.action == "book_appointment"')
fail_code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
  "$SERVER_URL/kiosk/book_appointment" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" -H "Content-Type: application/json" \
  -d '{"salon_id":987654,"slot":"2027-01-01T09:00:00Z"}')
assert "audit: a booking for a missing salon fails on the wire" \
  "$([ "$fail_code" -ge 400 ] && echo yes || echo "no($fail_code)")" "yes"
assert "audit: …and the FAILED invocation emitted an event too" \
  "$(event_count '.status == "error"')" "1"
assert "audit: …carrying the error class and message" \
  "$(event_count '.status == "error" and (.error_class | length > 0) and (.error_message | length > 0)')" "1"
# …AND THE HANDLER'S OWN EXCEPTION, NOT ONLY THE WIRE'S WRAPPER. The
# wire error is `action_failed` naming the exception CLASS and nothing else,
# because a handler's arbitrary sentence is not this protocol's to publish to
# an untrusted caller. A sink is the operator's own process, so it
# gets the wrapped exception too — which is the thing alerting is actually
# built on.
assert "audit: …and the handler's OWN error as the cause, not only the wrapper" \
  "$(event_count '.status == "error" and (.cause_class | length > 0) and (.cause_message | length > 0)')" "1"
assert "audit: …the wrapper and the cause are different exceptions" \
  "$(event_count '.status == "error" and .cause_class != .error_class')" "1"
assert "audit: …and nothing was booked for the missing salon" \
  "$(psql -X -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM appointments WHERE salon_id = 987654")" "0"
assert "audit: the sink saw exactly that one more invocation" \
  "$(( $(event_count '.action == "book_appointment"') - before_fail ))" "1"

# 7. A REFUSAL THAT NEVER REACHED AN ACTION EMITS NOTHING. A GET at an action's
#    path (a routing miss), a 401 with no token and a 404 for an unregistered
#    name all answer before anything is invoked — so this is an action trail,
#    not a request log.
before_refusals=$(events 'length')
curl -sS -o /dev/null "$SERVER_URL/kiosk/book_appointment" -H "Authorization: Bearer $ALICE_AGENT_TOKEN"
curl -sS -o /dev/null -X POST "$SERVER_URL/kiosk/book_appointment" -H "Content-Type: application/json" -d '{}'
curl -sS -o /dev/null -X POST "$SERVER_URL/kiosk/no_such_action" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" -H "Content-Type: application/json" -d '{}'
assert "audit: a routing miss, a 401 and a 404 emit nothing" \
  "$(( $(events 'length') - before_refusals ))" "0"

# 8. `pay` emits nothing — it is not an Action and it already writes the AP2
#    mandate trail asserted above, which is richer than one event could be.
assert "audit: pay emits no event" "$(event_count '.action == "pay"')" "0"

# 9. A SINK THAT RAISES DOES NOT FAIL THE ACTION. DemoAuditSink blows up on one
#    sentinel slot (its bug, planted on purpose). The booking must still be
#    served, must still land in the database, and must leave no event behind.
before_raise=$(events 'length')
raise_code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
  "$SERVER_URL/kiosk/book_appointment" \
  -H "Authorization: Bearer $ALICE_AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "{\"salon_id\":$salon_id,\"slot\":\"2030-01-01T00:00:00Z\"}")
assert "audit: a RAISING sink does not fail the action" "$raise_code" "200"
assert "audit: …the booking it choked on really landed" \
  "$(psql -X -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM appointments WHERE slot = '2030-01-01T00:00:00Z'")" "1"
assert "audit: …and the sink that raised emitted nothing" \
  "$(( $(events 'length') - before_raise ))" "0"

# 10. NO ENGINE-OWNED LOG TABLE. This origin was built by `rails g
#     kiosk:install` and migrated from scratch minutes ago, so this is the
#     canonical migration set speaking: it creates neither `kiosk.actions` nor
#     `kiosk.action_log`, and an operator who wants a trail sets `c.audit_sink`.
assert "audit: kiosk.action_log does not exist in a freshly migrated origin" \
  "$(psql -X -d "$DB_NAME" -tAc "SELECT to_regclass('kiosk.action_log') IS NULL")" "t"
assert "audit: …and neither does kiosk.actions" \
  "$(psql -X -d "$DB_NAME" -tAc "SELECT to_regclass('kiosk.actions') IS NULL")" "t"

# ─── summary ────────────────────────────────────────────────────────────

printf "\n\033[1m=== summary ===\033[0m\n"
printf "  pass: %s\n  fail: %s\n" "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ] || exit 1
