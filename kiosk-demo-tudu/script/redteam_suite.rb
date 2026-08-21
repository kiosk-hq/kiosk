# frozen_string_literal: true

# Adversarial regression battery for tudu (multi-user collaborative todo app).
#
# Runs a set of attacks against the live surface (my_lists / list_todos /
# list_members queries; create_list / add_todo / complete_todo / invite /
# accept_invite / remove_member actions) and asserts each is BLOCKED. tudu has
# no payment or KYC surface, so the battery covers the attacks that apply —
# membership isolation, forged principal args, the auth/dispatch boundary, PLUS
# tudu-specific collaboration attacks (invite replay, revoked-member access,
# revoked-agent login, pre-link token reach).
#
# Standard scenarios (each must be BLOCKED):
#   CrossTenantRead   — a non-member's list_todos on a private list → 403
#   ForgedUserId      — forged account_id on create_list REFUSED (400), and the
#                       caller's own list still belongs to the caller
#   MalformedUuidArg  — a junk list_id/todo_id/account_id on the wire-facing
#                       verbs is a typed 400 with no SQL internals — never a 500
#   MissingAuth       — a request with no Authorization → 401
#   GarbageToken      — an unparseable bearer token → 401
#   UnknownQuery      — an unregistered query name → 404
#   UnknownAction     — an unregistered action name → 404
#   RetiredWire       — the deleted 0.3 /kiosk/query + /kiosk/run endpoints are
#                       an ordinary 404, not a tombstone or a second surface
#   MethodMismatch    — a GET at an action's path → 405 + `Allow: POST`, never a
#                       silent 404 an assistant would read as "cannot do that"
# tudu-specific scenarios:
#   InviteCodeReplay      — an already-used invite code is rejected → 403
#   RevokedMemberAccess   — a removed member's next read is blocked → 403
#   RevokedAgentKey       — an unlinked agent's login is denied → 404
#   PreLinkTokenAfterLink — a token minted before rebind is watermark-revoked by
#                           the rebind (principal change) → 401
#
# Usage:
#   SERVER_URL=… KIOSK_ISSUER=… HOLDER_ID=… HOLDER_EMAIL=… HOLDER_PASSWORD=… \
#   bundle exec ruby script/redteam_suite.rb
#
# Exits 0 when every scenario is BLOCKED (0 BREACH); exits 1 on any BREACH.

require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "securerandom"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
HOLDER   = ENV.fetch("HOLDER_ID")
EMAIL    = ENV.fetch("HOLDER_EMAIL")
PASSWORD = ENV.fetch("HOLDER_PASSWORD")

# ── the human's browser session, and the wire helpers built on it ──────────
#
# ONE mechanism, shared: script/devise_session.rb holds the cookie jar, the CSRF
# read and the sign-in POST for every demo, and bin/check-demo-copies keeps the
# copies byte-identical. Each driver used to carry its own copy of that jar —
# five of them, free to drift, exactly the way script/equihash_register.rb drifted
# in three of five. These wrappers keep this driver's call sites unchanged.
require_relative "devise_session"

SESSION = DeviseSession.new(SERVER)

def request(req) = SESSION.request(req)
def get_html(path) = SESSION.get_html(path)
def post_form(path, form) = SESSION.post_form(path, form)
def csrf_token(html) = SESSION.csrf_token(html)

# session: true sends the human's cookie jar (the Devise session channel);
# agent calls send only their Bearer header — never the human's cookies.
def post_json(path, body, headers = {}) = SESSION.post_json(path, body, headers)
def get_json(path, params = {}, headers = {}) = SESSION.get_json(path, params, headers)

def bearer(token) = { "Authorization" => "Bearer #{token}" }
def csrf_token(html) = html[/name="authenticity_token" value="([^"]+)"/, 1]

def pop_proof(key, pem)
  rc, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "challenge failed (#{rc})" unless rc == 200
  JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
end

require_relative "equihash_register"

# The equihash_register helper injects full-URL get/post callables (tudu's own
# post_json/get_json take a path), so wrap them to accept a full URL. The plain
# GET wrapper carries no cookie jar — register needs no session.
GET_URL  = ->(url)                 { get_json(url.delete_prefix(SERVER)) }
POST_URL = ->(url, body, hdrs = {}) { post_json(url.delete_prefix(SERVER), body, hdrs) }

# Register a fresh agent, solving the register PoW transparently (register is
# uniformly tolled). Returns the keypair too — the pre-link scenario re-uses it.
def register_agent(_label)
  key, reg = equihash_register(server: SERVER, issuer: ISSUER, get_json: GET_URL, post_json: POST_URL)
  { key: key, pem: key.public_key.to_pem,
    token: reg.fetch("access_token"), agent_id: reg.fetch("agent_id"), user_id: reg.fetch("user_id") }
end

results = []
def record(results, name, blocked, detail)
  results << { name: name, blocked: blocked, detail: detail }
  puts "  #{blocked ? 'BLOCKED' : 'BREACH '}  #{name} — #{detail}"
end

# ── Fixtures: an owner with a private list; a member; an outsider ────────────
owner    = register_agent("owner")
member   = register_agent("member")
outsider = register_agent("outsider")

rc, created = post_json("/kiosk/create_list", { title: "Redteam target" }, bearer(owner[:token]))
abort "owner create_list failed (#{rc}) — run rake demo:setup" unless rc == 200
list_id = created["list_id"]
rc, inv = post_json("/kiosk/invite", { list_id: list_id }, bearer(owner[:token]))
invite_code = inv["code"]
post_json("/kiosk/accept_invite", { code: invite_code }, bearer(member[:token]))

# ── CrossTenantRead — outsider list_todos on the private list → 403 ──────────
rc, = get_json("/kiosk/list_todos", { list_id: list_id }, bearer(outsider[:token]))
record(results, "CrossTenantRead", rc == 403, "outsider list_todos → #{rc} (want 403)")

# ── ForgedUserId — outsider create_list with a forged account_id ─────────────
#
# THIS BEAT CHANGED SHAPE AT 0.4 AND GOT STRONGER, so it is worth saying what it
# now proves. Through 0.3 the forged argument was ACCEPTED by the wire and
# IGNORED by the handler, and the proof was indirect: the created list did not
# surface in the owner's my_lists. On the 0.4 wire `input_schema` is validated on
# every call and `create_list` declares `additionalProperties: false` with
# `title` as its only property — the principal is not one of its inputs — so the
# forgery is REFUSED before the handler runs, with a typed 400 naming the
# offending parameter. Both halves are asserted: the wire refuses it, AND the
# outsider's LEGITIMATE list lands under the outsider and never under the owner.
rc, forged = post_json("/kiosk/create_list",
                       { title: "Forged", account_id: owner[:user_id] },
                       bearer(outsider[:token]))
refused = rc == 400 && forged["code"] == "bad_request" && forged["detail"].to_s.include?("account_id")

rc_x, outsiders = post_json("/kiosk/create_list", { title: "Outsider's own" }, bearer(outsider[:token]))
outsider_list = outsiders["list_id"]
rc_o, o_lists = get_json("/kiosk/my_lists", {}, bearer(owner[:token]))
o_ids = Array(o_lists).map { |r| r["list_id"] }
record(results, "ForgedUserId",
       refused && rc_x == 200 && rc_o == 200 && !o_ids.include?(outsider_list),
       "forged account_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming account_id); " \
       "owner's lists #{o_ids.inspect} exclude the outsider's #{outsider_list.inspect}")

# ── MalformedUuidArg — junk ids must be a typed 400, never a 500 ────────────
# K-581/K-582: tudu casts three wire-supplied ids `::uuid` — `list_id` (via the
# KioskMembershipGate choke point every membership-gated verb opens with),
# complete_todo's `todo_id`, and remove_member's `account_id`. Before the
# UuidCheck guards, a malformed value made Postgres raise
# InvalidTextRepresentation, which is not a Kiosk error and escaped as a raw 500
# carrying the PG message. Three properties are asserted, not one: the status is
# 400 (a client mistake reported as such), the problem document's top-level
# `code` is the typed `bad_request` an assistant can branch on, and NO SQL
# internals reach the wire. All three ids are probed — a guard on the choke point
# alone would leave complete_todo and remove_member's account_id open.
MALFORMED_IDS = ["not-a-uuid", "1; DROP TABLE todos", "", "  "].freeze
SQL_INTERNALS = ["::uuid", "PG::", "22P02", "invalid input syntax"].freeze

uuid_probes = MALFORMED_IDS.flat_map do |junk|
  [
    # list_id via the membership guard — a QUERY, so the junk rides the query string.
    [-> { get_json("/kiosk/list_todos", { list_id: junk }, bearer(owner[:token])) },     "list_todos"],
    # todo_id — no other guard in front of the cast.
    [-> { post_json("/kiosk/complete_todo", { todo_id: junk }, bearer(owner[:token])) }, "complete_todo"],
    # account_id — the second id, on a verb whose FIRST id is well-formed.
    [-> { post_json("/kiosk/remove_member", { list_id: list_id, account_id: junk }, bearer(owner[:token])) },
     "remove_member"],
  ].map do |probe, verb|
    rc, resp = probe.call
    leak = SQL_INTERNALS.find { |needle| JSON.generate(resp).include?(needle) }
    ok = rc == 400 && resp["code"] == "bad_request" && leak.nil?
    [ok, "#{verb}(#{junk.inspect})→#{rc}/#{resp['code'].inspect}#{leak ? " LEAK #{leak}" : ''}"]
  end
end
record(results, "MalformedUuidArg", uuid_probes.all? { |ok, _| ok },
       "malformed list_id/todo_id/account_id → #{uuid_probes.map(&:last).join(', ')} " \
       "(want 400/\"bad_request\" and no SQL internals)")

# ── MissingAuth / GarbageToken → 401 ────────────────────────────────────────
rc, = get_json("/kiosk/my_lists")
record(results, "MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")
rc, = get_json("/kiosk/my_lists", {}, bearer("not-a-real-token"))
record(results, "GarbageToken", rc == 401, "garbage token → #{rc} (want 401)")

# ── UnknownQuery / UnknownAction → 404 ──────────────────────────────────────
rc, = get_json("/kiosk/frobnicate", {}, bearer(owner[:token]))
record(results, "UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")
rc, = post_json("/kiosk/nope", {}, bearer(owner[:token]))
record(results, "UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# ── RetiredWire — the deleted 0.3 endpoints are GONE, not tombstoned ─────────
# T-074 = A was a hard cut. `POST /kiosk/query` now reaches the per-verb
# controller as a verb literally named "query", which nobody registered, so it
# answers the ordinary 404 — no privileged endpoint, no compatibility payload,
# no second conformance surface to attack.
retired = %w[query run].map do |name|
  rc, body = post_json("/kiosk/#{name}", { name: "my_lists" }, bearer(owner[:token]))
  [rc == 404 && body["code"] == "not_found", "#{name}→#{rc}/#{body['code'].inspect}"]
end
record(results, "RetiredWire", retired.all? { |ok, _| ok },
       "0.3 endpoints #{retired.map(&:last).join(', ')} (want 404/\"not_found\")")

# ── MethodMismatch — a GET at an action's path is 405, never a silent 404 ────
# The resource EXISTS; answering 404 would be a lie about it, and a caller that
# read 404 as "this operator cannot do that" would give up on a verb it could
# have called correctly.
res405 = request(Net::HTTP::Get.new(URI("#{SERVER}/kiosk/create_list"), bearer(owner[:token])))
body405 = (JSON.parse(res405.body) rescue {})
record(results, "MethodMismatch",
       res405.code.to_i == 405 && body405["code"] == "method_not_allowed" &&
         res405["allow"].to_s.upcase.include?("POST"),
       "GET an action → #{res405.code}/#{body405['code'].inspect} Allow=#{res405['allow'].inspect} " \
       "(want 405/\"method_not_allowed\"/POST)")

# ── InviteCodeReplay — the member's used code, replayed by outsider → 403 ────
rc, = post_json("/kiosk/accept_invite", { code: invite_code }, bearer(outsider[:token]))
record(results, "InviteCodeReplay", rc == 403, "replay of used invite code → #{rc} (want 403)")

# ── RevokedMemberAccess — remove the member, its next read is blocked → 403 ─
post_json("/kiosk/remove_member", { list_id: list_id, account_id: member[:user_id] }, bearer(owner[:token]))
rc, = get_json("/kiosk/list_todos", { list_id: list_id }, bearer(member[:token]))
record(results, "RevokedMemberAccess", rc == 403, "removed member's next read → #{rc} (want 403)")

# ── Session-channel scenarios: Alice signs in for unlink + link ─────────────
begin
  SESSION.sign_in!(email: EMAIL, password: PASSWORD)
rescue DeviseSession::SignInError => e
  abort "#{e.message} — RevokedAgentKey needs a live Devise session"
end

# RevokedAgentKey — link a fresh assistant to Alice, unlink it, login → 404.
# K-688: a bare terminal 404 does not discriminate — AgentLogin's lookup
# (`WHERE public_key = … AND revoked_at IS NULL`) returns the identical 404
# for a key that was NEVER linked, so a beat that only checks the last status
# would still "pass" if link/claim silently failed. Assert every precondition
# on the way in (link 201, claim 201, an agent_id back), and add a POSITIVE
# CONTROL — login on the freshly-claimed key succeeds (200) BEFORE unlink —
# so the terminal 404 can only be read as "this key was just revoked".
rc_link, link = post_json("/kiosk/auth/link", {}, { session: true })
rk = OpenSSL::PKey::RSA.generate(2048); rpem = rk.public_key.to_pem
rc_claim, claimed = post_json("/kiosk/auth/claim", { code: link["link_code"], public_key: rpem, signed: pop_proof(rk, rpem) })
revoked_agent_id = claimed["agent_id"]
rc_prelogin, = post_json("/kiosk/auth/login", { public_key: rpem, signed: pop_proof(rk, rpem) })
rc_unlink, = post_json("/kiosk/auth/unlink", { agent_id: revoked_agent_id }, { session: true })
rc, = post_json("/kiosk/auth/login", { public_key: rpem, signed: pop_proof(rk, rpem) })
record(results, "RevokedAgentKey",
       rc_link == 201 && rc_claim == 201 && !revoked_agent_id.nil? &&
       rc_prelogin == 200 && rc_unlink == 200 && rc == 404,
       "link=#{rc_link} claim=#{rc_claim} agent_id=#{revoked_agent_id.inspect} " \
       "pre-revoke login=#{rc_prelogin} (want 200) unlink=#{rc_unlink} (want 200) " \
       "post-revoke login=#{rc} (want 404)")

# PreLinkTokenAfterLink — an agent registers headless, creates a list, then
# rebinds to Alice (assistant_claimed migrates the list). A rebind is a
# principal change, so — like unlink — it watermark-revokes the key's pre-link
# tokens. The PRE-LINK token no longer authenticates at all → 401.
pl = register_agent("prelink")
rc, plc = post_json("/kiosk/create_list", { title: "Pre-link list" }, bearer(pl[:token]))
pl_list = plc["list_id"]
rc, link2 = post_json("/kiosk/auth/link", {}, { session: true })
# Cross a second boundary so the pre-link token (minted at register above) is
# unambiguously older than the rebind watermark — JWT iat is second-resolution.
sleep 1.1
rc, = post_json("/kiosk/auth/claim", { code: link2["link_code"], public_key: pl[:pem], signed: pop_proof(pl[:key], pl[:pem]) })
rc, = get_json("/kiosk/list_todos", { list_id: pl_list }, bearer(pl[:token]))
record(results, "PreLinkTokenAfterLink", rc == 401,
       "pre-link token after rebind → #{rc} (want 401 — watermark-revoked)")

# ── Verdict ──────────────────────────────────────────────────────────────────
breaches = results.reject { |r| r[:blocked] }
puts JSON.generate(scenarios: results.size, blocked: results.count { |r| r[:blocked] }, breaches: breaches.map { |r| r[:name] })

if breaches.empty?
  puts "\n  redteam: all #{results.size} scenarios BLOCKED."
  exit 0
else
  puts "\n  redteam: #{breaches.size} BREACH(es): #{breaches.map { |r| r[:name] }.join(', ')}"
  exit 1
end
