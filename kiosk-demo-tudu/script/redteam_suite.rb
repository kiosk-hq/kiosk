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
#                       the ordinary 404 an authenticated caller gets (401
#                       without a bearer), not a tombstone or a second surface
#   MethodMismatch    — a GET at an action's path → 405 + `Allow: POST`, never a
#                       silent 404 an assistant would read as "cannot do that"
# tudu-specific scenarios:
#   InviteCodeReplay      — an already-used invite code is rejected → 403
#   RevokedMemberAccess   — a removed member's next read is blocked → 403
#   RevokedAgentKey       — an unlinked agent's login is denied → 404
#   PreLinkTokenAfterLink — a token minted before rebind is watermark-revoked by
#                           the rebind (principal change) → 401
#   NoLoginAddressOnTheRoster — a co-member's list_members carries display names
#                           and NO account address anywhere in the body (K-950)
#   ChosenNameNeverTheAddress — a visitor who signs up with a display name is
#                           named by it on a roster, never by what they log in
#                           with (the other end of the same rule)
#   DeviceGrantRoleSelfSelection (from `kiosk-redteam`, shared by every demo) —
#     the account-binding claim ceremony's UNAUTHENTICATED opening request
#     refuses `role`/`scope` at a DECLARED value as well as an invented one,
#     while the role-less request still opens the ceremony (K-072, K-1128)
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

# The shared harness. Required HERE rather than beside the one framework beat
# further down, because {Kiosk::Redteam::LeakScan} — the oracle every leak
# assertion in this file now asks — is needed from the first hostile-input beat
# onwards (T-121).
require "kiosk/redteam"

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
    # THE SCAN IS TOLD WHAT THIS PROBE SENT (T-121). tudu answers a bad id by
    # NAMING it back (`list_id "…" is not a uuid`), so the bytes searched for
    # SQL_INTERNALS are partly the probe's own; without `supplied:` a junk id
    # spelling `PG::` would be reported as a BREACH on its own echo, under a
    # runner whose prose says a BREACH means "fix the app, not the scenario".
    # {Kiosk::Redteam::LeakScan} discounts a needle only where those exact bytes
    # lie inside one contiguous run the probe supplied — not a blind `gsub`,
    # which could erase a real leak instead.
    scan = Kiosk::Redteam::LeakScan.scan(resp, SQL_INTERNALS, supplied: junk)
    ok = rc == 400 && resp["code"] == "bad_request" && !scan.leak?
    [ok, "#{verb}(#{junk.inspect})→#{rc}/#{resp['code'].inspect}" \
         "#{scan.leak ? " LEAK #{scan.leak}" : ''}#{scan.note}"]
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
# answers the ordinary 404 an AUTHENTICATED caller gets — no privileged
# endpoint, no compatibility payload, no second conformance surface to attack.
#
# BOTH CALLERS ARE PROBED, and that is the whole point of the qualifier above
# (K-1094). `VerbController#serve` resolves the identity BEFORE it looks the
# verb up, so a caller with no bearer never reaches the registry lookup that
# produces the 404 — it is answered 401 `unauthenticated`, exactly as it would
# be at any other name. Every retired-wire beat in the fleet dialled WITH a
# bearer, so seven suites' prose said the 404 flatly while nothing anywhere
# tested the anonymous case the sentence was wrong about.
retired = %w[query run].map do |name|
  rc, body = post_json("/kiosk/#{name}", { name: "my_lists" }, bearer(owner[:token]))
  [rc == 404 && body["code"] == "not_found", "#{name}→#{rc}/#{body['code'].inspect}"]
end
retired_anon = %w[query run].map do |name|
  rc, body = post_json("/kiosk/#{name}", { name: "my_lists" })
  [rc == 401 && body["code"] == "unauthenticated", "#{name}(anon)→#{rc}/#{body['code'].inspect}"]
end
record(results, "RetiredWire", (retired + retired_anon).all? { |ok, _| ok },
       "0.3 endpoints #{(retired + retired_anon).map(&:last).join(', ')} " \
       "(want 404/\"not_found\" with a bearer, 401/\"unauthenticated\" without)")

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
       rc_prelogin == 200 && rc_unlink == 204 && rc == 404,
       "link=#{rc_link} claim=#{rc_claim} agent_id=#{revoked_agent_id.inspect} " \
       "pre-revoke login=#{rc_prelogin} (want 200) unlink=#{rc_unlink} (want 204) " \
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

# ── NoLoginAddressOnTheRoster (K-950) ────────────────────────────────────────
#
# THE BEAT THAT HAS TO SURVIVE A REFACTOR, and tudu's twin of philslist's
# NoSellerPiiOnTheOpenBoard. `list_members` is the most cross-principal verb
# tudu has — the rows ARE other accounts — and until K-950 the column it
# published was `users.email`, so every housemate on a shared list walked away
# with every other housemate's LOGIN ADDRESS. Consent bought the roster; it
# never bought the credential, and spec Section 7.2 now says so at EVERY reach
# rather than only at `published`. The projection is one `pluck` line; nothing
# but an assertion stops a future edit from putting the column back.
#
# THE PROBE RUNS AS AN ASSISTANT BOUND TO ALICE and reads the SEEDED household
# ("Flat 3B"), because that is the only roster on this origin whose members are
# HUMANS WITH ADDRESSES — the three fixture agents above are headless accounts
# with no email at all, so a probe over their list would pass vacuously no
# matter what the projection did. Alice reading Bob's row is exactly the
# position the row was filed about: a consented co-member, learning what the
# verb tells it about the people it already shares a list with.
#
# Four things are asserted, and the last three are what make the first
# non-vacuous:
#   1. NO account address anywhere in the response — the RAW BODY is searched
#      for Alice's seeded address and for `@` at all, not just the field that
#      used to hold it. A leak that moved to another key, or into a debug
#      field, is the same leak.
#   2. Every row carries a non-empty `display_name`. A handler that dropped the
#      field entirely would fail here, so the beat cannot be passed by
#      publishing nothing.
#   3. The seeded household still reads as a household — "Alice" and "Bob", the
#      names those accounts chose. This is the half philslist does NOT have:
#      an opaque handle would satisfy (1) and (2) and destroy the verb, since
#      "who added the tent?" is what a roster is for.
#   4. A HEADLESS account — one that chose no name, which is every
#      assistant-created principal — is named by an opaque `member-<12 hex>`,
#      distinct per account. That pins the fallback's shape and its derivation
#      from the account UUID rather than from anything a reader can enumerate.
#
# SESSION is still signed in as Alice from the scenarios above, so the ordinary
# link/claim/login ceremony is all it takes to stand where an assistant stands.
pii_rc_link, pii_link = post_json("/kiosk/auth/link", {}, { session: true })
pii_key = OpenSSL::PKey::RSA.generate(2048)
pii_pem = pii_key.public_key.to_pem
pii_rc_claim, = post_json("/kiosk/auth/claim",
                          { code: pii_link["link_code"], public_key: pii_pem, signed: pop_proof(pii_key, pii_pem) })
pii_rc_login, pii_login = post_json("/kiosk/auth/login",
                                    { public_key: pii_pem, signed: pop_proof(pii_key, pii_pem) })
pii_bearer = bearer(pii_login["access_token"].to_s)

rc_mine, mine = get_json("/kiosk/my_lists", {}, pii_bearer)
household = Array(mine).find { |r| r["title"] == "Flat 3B" }
rc_roster, roster = get_json("/kiosk/list_members", { list_id: household && household["list_id"] }, pii_bearer)
rc_who, who = get_json("/kiosk/whoami", {}, pii_bearer)

# `is_a?(Array)` on every body before indexing it, philslist's rule: a verb that
# 500s answers with a problem-document HASH, and a beat that assumed an array
# would die with a TypeError instead of reporting a BREACH. This is not
# hypothetical here — restoring the old projection makes `list_members` render a
# payload its own `output_schema` rejects, so the engine answers 500 and this
# beat must still say WHY.
raw_roster   = JSON.generate(roster) + JSON.generate(who)
roster_rows  = roster.is_a?(Array) ? roster : []
who_rows     = who.is_a?(Array) ? who : []
roster_names = roster_rows.map { |r| r["display_name"] }
no_addresses = !raw_roster.include?(EMAIL) && !raw_roster.include?("@")
named        = roster_rows.length >= 2 &&
               roster_names.all? { |n| n.is_a?(String) && !n.strip.empty? }
recognisable = (roster_names & %w[Alice Bob]).sort == %w[Alice Bob]

# The headless half: the fixture agents' own list. Both principals on it
# registered through /auth/register, so neither has an address OR a chosen name.
# The outsider is re-invited first, because RevokedMemberAccess above removed
# the original member — a one-row roster would prove the pseudonym's SHAPE
# without proving it is per-account, and per-account is half of what makes it a
# name rather than a constant.
_, rejoin = post_json("/kiosk/invite", { list_id: list_id }, bearer(owner[:token]))
post_json("/kiosk/accept_invite", { code: rejoin["code"] }, bearer(outsider[:token]))
rc_headless, headless = get_json("/kiosk/list_members", { list_id: list_id }, bearer(owner[:token]))
headless_names = (headless.is_a?(Array) ? headless : []).map { |r| r["display_name"] }
opaque_ok = headless_names.length >= 2 &&
            headless_names.all? { |n| n.to_s.match?(/\Amember-[0-9a-f]{12}\z/) } &&
            headless_names.uniq.length == headless_names.length

record(results, "NoLoginAddressOnTheRoster",
       pii_rc_link == 201 && pii_rc_claim == 201 && pii_rc_login == 200 &&
       rc_mine == 200 && rc_roster == 200 && rc_who == 200 && rc_headless == 200 &&
       no_addresses && named && recognisable && opaque_ok,
       "link=#{pii_rc_link} claim=#{pii_rc_claim} login=#{pii_rc_login}; " \
       "list_members on the seeded household as Alice's assistant → #{rc_roster}, " \
       "#{roster_rows.length} rows named #{roster_names.inspect}; whoami → #{rc_who} " \
       "#{who_rows.first&.fetch('display_name', nil).inspect}; account addresses in " \
       "roster+whoami body: #{no_addresses ? 'none' : 'FOUND'}; headless roster → " \
       "#{rc_headless} #{headless_names.inspect} " \
       "(want no address anywhere, every row a non-empty display_name, the seeded " \
       "household reading as Alice+Bob, and each headless account an opaque " \
       "`member-<12 hex>`)")

# ── ChosenNameNeverTheAddress (K-950) ────────────────────────────────────────
#
# The other end of the same rule, and the reason tudu carries a `display_name`
# field on its sign-up form when atablefor (whose diners are seeded) does not:
# tudu is the fleet's ONE demo with open registration, so if a visitor cannot
# name themselves, every real person who joins a household is published as a
# hash — safe, and useless to the people who invited them. This walks the
# shipped surfaces end to end: the real Devise form, the real list page.
#
# ITS OWN COOKIE JAR, deliberately. SESSION is Alice's browser and the beats
# above still need it; Devise also refuses a sign-up from an already-signed-in
# session, so sharing one jar would have made this beat pass for the wrong
# reason.
#
# NOTE WHAT IS *NOT* ASSERTED: that the whole page carries no `@`. The layout
# greets a signed-in human with their own address, which is a disclosure to its
# own owner and no disclosure at all. The assertion is scoped to the Members
# block — the one place a page names OTHER people — which is the same
# distinction Section 7.2 draws.
signup       = DeviseSession.new(SERVER)
chosen_name  = "Cassie Housemate"
signup_email = "cassie-#{SecureRandom.hex(4)}@example.com"
signup_form  = signup.get_html("/users/sign_up")
signup_res   = signup.post_form("/users",
                                "authenticity_token"          => signup.csrf_token(signup_form.body),
                                "user[display_name]"          => chosen_name,
                                "user[email]"                 => signup_email,
                                "user[password]"              => PASSWORD,
                                "user[password_confirmation]" => PASSWORD)
lists_page   = signup.get_html("/lists")
# The token is read from the NEW-LIST form specifically, not from the first one
# on the page: the layout renders a `button_to "Sign out"` above the yield, and
# with per-form CSRF tokens the document's first token is bound to
# (DELETE, /users/sign_out) and is rejected at (POST, /lists) with a 422.
new_list_form = lists_page.body.to_s[%r{<form[^>]*action="/lists"[^>]*>.*?</form>}m].to_s
create_res   = signup.post_form("/lists",
                                "authenticity_token" => signup.csrf_token(new_list_form),
                                "title"              => "Cassie's shelf")
list_page    = signup.get_html(create_res["location"].to_s)
members_html = list_page.body.to_s[%r{<h2>Members</h2>.*?</ul>}m].to_s

record(results, "ChosenNameNeverTheAddress",
       signup_form.code.to_i == 200 && [302, 303].include?(signup_res.code.to_i) &&
       [302, 303].include?(create_res.code.to_i) && list_page.code.to_i == 200 &&
       members_html.include?(chosen_name) && !members_html.include?("@"),
       "sign-up form → #{signup_form.code}, sign-up → #{signup_res.code}, " \
       "create list → #{create_res.code}, list page → #{list_page.code}; members block " \
       "#{members_html.gsub(/\s+/, ' ').strip.inspect} " \
       "(want the chosen name #{chosen_name.inspect} there and no address in it)")

# ── DeviceGrantRoleSelfSelection — the SHARED framework beat (K-1128) ────────
#
# The one beat in this file that is NOT hand-rolled: it comes from
# `kiosk-redteam`, so every demo runs the SAME assertion about the
# account-binding claim ceremony and a demo cannot be left out of it by
# forgetting to copy a block.
#
# It exists because the coverage that was supposed to catch K-072 rested on a
# condition nobody re-measured: the shared `PrivilegeSelfSelection` scenario
# probes `/auth/register` only, and the ceremony beats written when K-072 was
# fixed lived in ONE demo's suite. The other six were safe purely because each
# declares a single role — which is exactly the mitigation the ledger row had
# priced K-072 on, and which expired unnoticed the day a demo declared a
# second one.
#
# `declared_roles` names what `config/initializers/kiosk.rb` declares here. The
# scenario ALSO derives a declared role from the wire (the `role` claim of a
# token this origin mints at registration), so a stale list weakens the probe
# rather than emptying it — an invented role was refused by the vulnerable code
# too, which is why a probe that names only one cannot fail.
device_grant_beat    = Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new
device_grant_verdict = device_grant_beat.call(
  Kiosk::Redteam::Client.new(base_url: SERVER),
  Kiosk::Redteam::Profile.new(pow_difficulty: 1, declared_roles: %w[customer]),
)
# A SKIP is recorded as a breach here on purpose: this origin declares a role,
# so "could not test" is a failure of the harness rather than a property of the
# provider, and a silent third state is what let the last one hide.
record(results, device_grant_beat.name, device_grant_verdict.blocked,
       device_grant_verdict.skipped ? "SKIPPED, which this origin must never do — " \
                                      "#{device_grant_verdict.detail}"
                                    : device_grant_verdict.detail)

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
