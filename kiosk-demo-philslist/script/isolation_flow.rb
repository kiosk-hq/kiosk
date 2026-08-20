# frozen_string_literal: true

# Adversarial cross-owner isolation test driver for philslist.
#
# Unlike stylish (whose book_appointment targets an open catalogue, so
# ownership-denial is N/A), philslist listings are OWNED resources — this is the
# first demo where cross-owner WRITE denial is the headline.
#
# Assertions (parsed by rake demo:isolation):
#   1  browse_listings returns BOTH owners' open listings to each caller
#      (open board — positive control that browse is genuinely cross-owner).
#   2a Bob's my_listings EXCLUDES Alice's listing.
#   2b Bob's my_listings INCLUDES Bob's own (non-vacuous positive control).
#   3  Bob edit_listing on ALICE's listing → 403 (cross-owner write denial).
#   4  Bob close_listing on ALICE's listing → 403.
#   5  Forged owner_id arg on Bob's post_listing is REFUSED at the declared
#      input contract (400 bad_request naming owner_id), and Bob's legitimate
#      listing is owned by Bob in the DB, and attributed to Bob's MINTED agent
#      id (both verified via psql in the rake task) — the principal comes from
#      the token, and is not an input at all.
#
# THE TWO PRINCIPALS ARE EARNED, NOT ASSERTED (T-104). This driver used to hand
# itself both identities by writing them down — `agent:u-<uuid>:a-<uuid>:r-customer`
# — which a dev-only parser inside the demo's own agent-IdP turned into an
# authenticated identity at whatever role the string asked for. That parser is
# deleted and nothing replaced it, so each principal here runs the shipped
# ceremony instead (lib/bound_assistant.rb: Equihash-tolled `/auth/register` →
# the human's real Devise sign-in → `/auth/link` → `/auth/claim`). Alice and Bob
# hold SEPARATE Devise sessions because they are separate humans.
#
# The claim is a REBIND, which is why the ownership assertions below still read
# as "Alice's rows" and "Bob's rows": the headless account `/auth/register`
# minted is remapped onto the seeded human, so each assistant's `user_id` IS its
# human's seeded uuid. The `agent_id`, by contrast, is MINTED and cannot be
# chosen — `kiosk.agents.id`, every `kiosk.*_mandates.agent_id` and
# `kiosk.current_agent_id()` are typed `uuid` in the canonical schema, so a
# driver naming its own agent id was naming a shape the shipped tables may not
# be able to store (K-829/K-830).
#
# Users/listings pre-seeded by demo:setup (db/seeds.rb); the credentials arrive
# in the environment from the rake task, never as literals here.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3006 KIOSK_ISSUER=http://127.0.0.1:3006 \
#   ALICE_EMAIL=alice@example.com BOB_EMAIL=bob@example.com \
#   DEMO_PASSWORD=… bundle exec ruby script/isolation_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any hard transport failure.

require "json"
require "net/http"
require "uri"

require_relative "../lib/bound_assistant"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER", SERVER)

# The seeded humans behind the two assistants. Emails and password come from the
# environment — db/seeds.rb owns them and the rake task passes them through, the
# same way demo:binding passes HOLDER_EMAIL/HOLDER_PASSWORD. A password literal
# in a driver is a second place for it to be true.
ALICE_EMAIL = ENV.fetch("ALICE_EMAIL")
BOB_EMAIL   = ENV.fetch("BOB_EMAIL")
PASSWORD    = ENV.fetch("DEMO_PASSWORD")

# THE 0.4 WIRE. An action is `POST <endpoint>/<action-name>` with its
# arguments as the JSON body; a query is `GET <endpoint>/<query-name>` with its
# arguments in the query string. There is no `name` field and no /query or
# /run endpoint. A success body IS the result — a bare array from a
# non-paginating query, the action's own object from an action — and an error
# is an RFC 9457 problem document whose branch point is the top-level `code`.
def post_json(path, body, headers = {})
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(path, params = {}, headers = {})
  uri = URI("#{SERVER}#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  req = Net::HTTP::Get.new(uri, headers)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── Step 0: two principals, each EARNED through the shipped ceremony ─────────
alice = bind_assistant(server: SERVER, issuer: ISSUER, email: ALICE_EMAIL, password: PASSWORD)
bob   = bind_assistant(server: SERVER, issuer: ISSUER, email: BOB_EMAIL,   password: PASSWORD)
STDERR.puts "  A bound: agent=#{alice.agent_id} user=#{alice.user_id} role=#{alice.claims["role"].inspect}"
STDERR.puts "  B bound: agent=#{bob.agent_id} user=#{bob.user_id} role=#{bob.claims["role"].inspect}"

# The whole file asserts a boundary BETWEEN two principals. If the ceremony ever
# handed both assistants the same account the exclusions below would pass while
# proving nothing, so say so here rather than let a green run lie.
abort "both assistants bound to the SAME account (#{alice.user_id}) — no boundary to test" \
  if alice.user_id == bob.user_id
abort "both assistants share an agent id (#{alice.agent_id}) — registration is not minting" \
  if alice.agent_id == bob.agent_id

# ── Step 1: both principals post a listing so the board is cross-owner ────────
rc, alice_post = post_json("/kiosk/post_listing",
                           { category_slug: "furniture",
                             title: "Alice bookshelf", body: "Pine, 5-shelf", price_text: "€80" },
                           alice.bearer)
abort "A post_listing failed (#{rc}): #{JSON.generate(alice_post)}" unless rc == 200
alice_listing_id = alice_post["listing_id"]
abort "A listing_id missing: #{JSON.generate(alice_post)}" unless alice_listing_id
STDERR.puts "  A posted listing #{alice_listing_id}"

rc, bob_post = post_json("/kiosk/post_listing",
                         { category_slug: "bikes",
                           title: "Bob mountain bike", body: "Hardtail, size L", price_text: "€500" },
                         bob.bearer)
abort "B post_listing failed (#{rc}): #{JSON.generate(bob_post)}" unless rc == 200
bob_listing_id = bob_post["listing_id"]
abort "B listing_id missing: #{JSON.generate(bob_post)}" unless bob_listing_id
STDERR.puts "  B posted listing #{bob_listing_id}"

# ── Step 2: browse_listings is cross-owner (Assertion 1) ─────────────────────
rc, browse = get_json("/kiosk/browse_listings", {}, bob.bearer)
abort "browse_listings failed (#{rc}): #{JSON.generate(browse)}" unless rc == 200
browse_ids = Array(browse).map { |r| r["listing_id"] }
STDERR.puts "  B browse_listings ids: #{browse_ids.inspect}"

# ── Step 3: Bob's my_listings — scoped (Assertions 2a/2b) ────────────────────
rc, bmine = get_json("/kiosk/my_listings", {}, bob.bearer)
abort "B my_listings failed (#{rc}): #{JSON.generate(bmine)}" unless rc == 200
b_my_ids = Array(bmine).map { |r| r["listing_id"] }
STDERR.puts "  B my_listings ids: #{b_my_ids.inspect}"

# ── Step 4: Bob edit_listing on ALICE's listing → 403 (Assertion 3) ──────────
edit_rc, edit_body = post_json("/kiosk/edit_listing",
                               { listing_id: alice_listing_id, price_text: "€1" },
                               bob.bearer)
STDERR.puts "  B edit Alice's listing → #{edit_rc}"

# ── Step 5: Bob close_listing on ALICE's listing → 403 (Assertion 4) ─────────
close_rc, close_body = post_json("/kiosk/close_listing",
                                 { listing_id: alice_listing_id },
                                 bob.bearer)
STDERR.puts "  B close Alice's listing → #{close_rc}"

# ── Step 6: forged owner_id arg on Bob's post_listing (Assertion 5) ──────────
#
# Bob's token identifies Bob; the forged arg supplies Alice's UUID — read off
# Alice's OWN bound token rather than written down here, so the forgery names
# the account this run actually created rows under. On the 0.4 wire this is
# REFUSED before the handler runs: `post_listing` publishes
# `additionalProperties: false` and does not declare `owner_id` — the principal
# is not one of its inputs — so the declared input contract answers a typed 400
# naming the parameter. (Through 0.3 the argument was accepted and silently
# ignored; refusing it is the stricter answer and the one the published
# contract requires.)
forged_rc, forged = post_json("/kiosk/post_listing",
                              { category_slug: "electronics",
                                title: "Forged owner test", body: "should belong to Bob",
                                owner_id: alice.user_id },
                              bob.bearer)
STDERR.puts "  B post_listing with a forged owner_id → #{forged_rc} #{forged['code'].inspect}"

# And the second half, which the refusal does not by itself prove: ownership and
# attribution are taken from the AUTHENTICATED identity. Bob posts legitimately;
# the rake task reads the row back and asserts owner_id == Bob's account and
# created_by_agent_id == the agent id `/auth/register` MINTED for Bob.
rc, legit = post_json("/kiosk/post_listing",
                      { category_slug: "electronics",
                        title: "Owner-from-token test", body: "must belong to Bob" },
                      bob.bearer)
abort "B post_listing failed (#{rc}): #{JSON.generate(legit)}" unless rc == 200
owner_probe_listing_id = legit["listing_id"]
STDERR.puts "  B posted (owner from token): #{owner_probe_listing_id}"

puts JSON.generate(
  user_id_a:          alice.user_id,
  user_id_b:          bob.user_id,
  agent_id_a:         alice.agent_id,
  agent_id_b:         bob.agent_id,
  alice_listing_id:   alice_listing_id,
  bob_listing_id:     bob_listing_id,
  browse_ids:         browse_ids,
  b_my_ids:           b_my_ids,
  cross_owner_edit:   [edit_rc, edit_body["code"]],
  cross_owner_close:  [close_rc, close_body["code"]],
  forged_refusal:     [forged_rc, forged["code"], forged["detail"]],
  owner_probe_listing_id: owner_probe_listing_id,
)
