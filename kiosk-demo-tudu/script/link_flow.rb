# frozen_string_literal: true

# tudu account-link driver — the W5 REBIND + DOMAIN-MIGRATION beat, the first
# real use of the assistant_claimed hook in the repo.
#
# Scenario (all over real HTTP against the live app):
#   1. An assistant registers with a FRESH key as a HEADLESS account (PoP
#      register → its own users row, no human behind it) and, as that headless
#      account, creates the "Hike" list.
#   2. The human (Alice) signs in through the real Devise form, and mints a
#      LINK code (POST /kiosk/auth/link, session channel).
#   3. The SAME assistant key redeems the code (POST /kiosk/auth/claim, key+PoP)
#      → REBIND: agent_id stays stable, agents.user_id remaps to Alice, and the
#      assistant_claimed hook MIGRATES the headless account's list to Alice.
#
# Asserts:
#   (a) after link, the pre-existing "Hike" list now belongs to Alice
#       (assistant_claimed migrated it — verified in the rake task via psql);
#   (b) the PRE-LINK token no longer authenticates at all — a rebind is a
#       principal change, so (like unlink) it watermark-revokes the key's
#       pre-link tokens. The old token now fails with 401, forcing the
#       agent to re-login for a token under the new principal.
#   (c) after the assistant RE-LOGS IN (fresh token, sub=Alice), it sees "Hike"
#       under Alice — and Alice's browser session (my_lists as the human) sees
#       the same list. One shared world.
#   (d) Alice ends with the linked agent bound to her (DB ground truth);
#   (e) RE-LINKING the same, already-bound key is a NO-OP — it migrates
#       nothing and, above all, destroys nothing (K-783).

require "date"
require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "securerandom"
require "base64"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
HOLDER   = ENV.fetch("HOLDER_ID")
EMAIL    = ENV.fetch("HOLDER_EMAIL")
PASSWORD = ENV.fetch("HOLDER_PASSWORD")

# ── the human's browser session, and the wire helpers built on it ──────────
#
# ONE mechanism, shared: lib/devise_session.rb holds the cookie jar, the CSRF
# read and the sign-in POST for every demo, and bin/check-demo-copies keeps the
# copies byte-identical. Each driver used to carry its own copy of that jar —
# five of them, free to drift, exactly the way lib/equihash_register.rb drifted
# in three of five. These wrappers keep this driver's call sites unchanged.
require_relative "../lib/devise_session"

SESSION = DeviseSession.new(SERVER)

def request(req) = SESSION.request(req)
def get_html(path) = SESSION.get_html(path)
def post_form(path, form) = SESSION.post_form(path, form)
def csrf_token(html) = SESSION.csrf_token(html)

# session: true sends the human's cookie jar (the Devise session channel);
# agent calls send only their Bearer header — never the human's cookies.
def post_json(path, body, headers = {}) = SESSION.post_json(path, body, headers)
def get_json(path, params = {}, headers = {}) = SESSION.get_json(path, params, headers)

def pop_proof(key, pem)
  rc, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "challenge failed (#{rc}): #{JSON.generate(ch)}" unless rc == 200
  JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
end

def jwt_claims(token)
  seg = token.split(".")[1]
  JSON.parse(Base64.urlsafe_decode64(seg + "=" * ((4 - seg.length % 4) % 4)))
end

def bearer(token) = { "Authorization" => "Bearer #{token}" }

results = {}

# ── 1. Assistant registers HEADLESS and creates the "Hike" list ─────────────
# equihash_register solves the register PoW transparently (register is uniformly
# tolled) and returns the SAME keypair the later claim/login re-use. Its injected
# get/post callables take a full URL; tudu's own helpers take a path, so wrap.
require_relative "../lib/equihash_register"
get_url  = ->(url)                 { get_json(url.delete_prefix(SERVER)) }
post_url = ->(url, body, hdrs = {}) { post_json(url.delete_prefix(SERVER), body, hdrs) }
key, reg = equihash_register(server: SERVER, issuer: ISSUER, get_json: get_url, post_json: post_url)
pem = key.public_key.to_pem
headless_token   = reg.fetch("access_token")
agent_id         = reg.fetch("agent_id")
headless_user_id = reg.fetch("user_id")
results[:headless_agent_id]    = agent_id
results[:headless_user_id]     = headless_user_id
STDERR.puts "  Assistant registered headless: agent_id=#{agent_id} user_id=#{headless_user_id}"

rc, created = post_json("/kiosk/create_list", { title: "Hike" }, bearer(headless_token))
abort "headless create_list failed (#{rc}): #{JSON.generate(created)}" unless rc == 200
list_id = created["list_id"]
results[:list_id] = list_id
STDERR.puts "  Headless assistant created list #{list_id}"

# ── 2. Human signs in and mints a link code ─────────────────────────────────
SESSION.sign_in!(email: EMAIL, password: PASSWORD)
results[:human_signed_in] = true

rc, link = post_json("/kiosk/auth/link", {}, { session: true })
results[:link_mint] = rc
abort "link mint failed (#{rc}): #{JSON.generate(link)}" unless rc == 201

# ── 3. The SAME key redeems the code → REBIND + assistant_claimed migration ──
# The rebind watermark-revokes tokens minted STRICTLY before it (JWT iat is
# second-resolution). Cross a second boundary so the pre-link token, minted
# above, is unambiguously older than the rebind instant — over a real network
# these steps span seconds; the sleep just makes the local demo deterministic.
sleep 1.1
rc, claimed = post_json("/kiosk/auth/claim",
                        { code: link.fetch("link_code", ""), public_key: pem, signed: pop_proof(key, pem) })
results[:claim_status]        = rc
results[:claim_rebound_to_holder] = claimed["user_id"] == HOLDER
results[:claim_same_agent_id] = claimed["agent_id"] == agent_id
abort "claim failed (#{rc}): #{JSON.generate(claimed)}" unless rc == 201
STDERR.puts "  Rebind: agent_id=#{claimed['agent_id']} now user_id=#{claimed['user_id']} (was #{headless_user_id})"

# (b) The PRE-LINK token is watermark-revoked by the rebind (principal change ⇒
#     the agent must re-login) — its next call is rejected 401, not merely empty.
rc, _prelink = get_json("/kiosk/my_lists", {}, bearer(headless_token))
results[:prelink_status]   = rc
results[:prelink_revoked]  = rc == 401

# (c) The assistant RE-LOGS IN (fresh token bound to Alice) and sees "Hike".
rc, relog = post_json("/kiosk/auth/login", { public_key: pem, signed: pop_proof(key, pem) })
abort "re-login failed (#{rc}): #{JSON.generate(relog)}" unless rc == 200
new_token = relog.fetch("access_token")
results[:relogin_sub_is_holder] = jwt_claims(new_token)["sub"] == HOLDER
rc, after = get_json("/kiosk/my_lists", {}, bearer(new_token))
results[:agent_sees_migrated_list] = rc == 200 && Array(after).any? { |r| r["list_id"] == list_id && r["role"] == "owner" }

# Alice's browser session sees the same list over the web (my_lists as human).
alice_view = get_html("/lists")
results[:human_sees_migrated_list] = alice_view.code.to_i == 200 && alice_view.body.include?("Hike")

# Link a SECOND assistant to Alice so she ends with >=2 non-revoked agents.
rc, link2 = post_json("/kiosk/auth/link", {}, { session: true })
key2 = OpenSSL::PKey::RSA.generate(2048)
pem2 = key2.public_key.to_pem
rc, claimed2 = post_json("/kiosk/auth/claim",
                         { code: link2.fetch("link_code", ""), public_key: pem2, signed: pop_proof(key2, pem2) })
results[:second_agent_id]        = claimed2["agent_id"]
results[:second_bound_to_holder] = claimed2["user_id"] == HOLDER

# ── 4. RE-LINKING AN ALREADY-BOUND KEY IS A NO-OP, NOT A MIGRATION (K-783) ───
# Alice mints one more link code and the FIRST key — already bound to her by
# beat 3 — redeems it. Nothing transitions: `previous_user_id == user_id`, so
# there is no headless account to migrate from and no principal change to
# notify anyone about.
#
# Why this beat exists: before K-783 the engine called `assistant_claimed`
# anyway, and tudu's hook then DESTROYED the human's access to every list she
# was a member of. The migration UPDATE moved nothing (she is already a member
# of her own lists, so the "skip what they already have" guard skipped
# everything) and the trailing DELETE — whose only job is to drop the now-
# redundant HEADLESS memberships — deleted all of Alice's instead. She kept
# owning the rows and could no longer see them.
rc, link3 = post_json("/kiosk/auth/link", {}, { session: true })
results[:relink_mint] = rc
abort "re-link mint failed (#{rc}): #{JSON.generate(link3)}" unless rc == 201
rc, claimed3 = post_json("/kiosk/auth/claim",
                         { code: link3.fetch("link_code", ""), public_key: pem, signed: pop_proof(key, pem) })
results[:relink_status]        = rc
results[:relink_same_agent_id] = claimed3["agent_id"] == agent_id
results[:relink_still_holder]  = claimed3["user_id"] == HOLDER
abort "re-link claim failed (#{rc}): #{JSON.generate(claimed3)}" unless rc == 201

# The assistant's OWN view is what an agent can actually see, and it is
# membership-scoped: "Hike" comes back only while Alice's membership row
# survives. The claim's token is the current one (a re-bind still watermark-
# revokes, so `new_token` from beat (c) is dead by now).
rc, after_relink = get_json("/kiosk/my_lists", {}, bearer(claimed3["access_token"]))
results[:relink_keeps_list_access] =
  rc == 200 && Array(after_relink).any? { |r| r["list_id"] == list_id && r["role"] == "owner" }
# The human's browser sees BOTH her lists: the migrated "Hike" and the seeded
# "Flat 3B" household she was a member of long before any assistant existed.
alice_after = get_html("/lists")
results[:human_keeps_all_lists] =
  alice_after.code.to_i == 200 && alice_after.body.include?("Hike") && alice_after.body.include?("Flat 3B")

# ── 5. THE LIST'S OWN PAGE — the READ half of the human UI (T-082) ───────────
# /lists renders one projection (List.reachable_rows); /lists/:id renders the
# other two (Todo.rows_on, Membership.rows_on) BEHIND the same ListAccess gate the
# wire's query handlers use. Until T-082 that page reached its rows by dispatching
# a synthetic Rack sub-request at those handlers — the human UI travelling through
# the wire dispatcher — and nothing anywhere covered it, so the conversion off it
# had no regression net. This is that net, and it is two beats because the page
# has two answers: the roster a member may read, and the refusal a non-member
# earns.
list_page = get_html("/lists/#{list_id}")
results[:human_reads_list_page] =
  list_page.code.to_i == 200 && list_page.body.include?("Members") && list_page.body.include?(EMAIL)

# A well-formed list id Alice is not a member of: the gate answers `forbidden`,
# which this page presents as a redirect back to /lists with a flash — never a
# 500, and never somebody else's roster. The id is a valid uuid that no seed or
# beat creates, so the only thing standing between it and the page is the
# membership predicate.
foreign_page = get_html("/lists/00000000-0000-0000-0000-0000000000ff")
results[:human_foreign_list_refused] =
  [302, 303].include?(foreign_page.code.to_i) && !foreign_page.body.to_s.include?("Members")

puts JSON.generate(results)
