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
#      listing is owned by Bob in the DB (verified via psql in the rake task) —
#      the principal comes from the token, and is not an input at all.
#
# StubIdp shape: "agent:u-<uuid>:a-<agent_id>:r-<role>" — no RSA registration
# needed. Users/listings pre-seeded by demo:setup (db/seeds.rb).
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3006 KIOSK_ISSUER=http://127.0.0.1:3006 \
#   bundle exec ruby script/isolation_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any hard transport failure.

require "json"
require "net/http"
require "uri"

SERVER = ENV.fetch("SERVER_URL")

ALICE_UUID = "00000000-0000-0000-0000-000000000001"
BOB_UUID   = "00000000-0000-0000-0000-000000000002"

# The agent id is a UUID, not a readable slug: `kiosk.agents.id`, every
# `kiosk.*_mandates.agent_id` and `kiosk.current_agent_id()` are all typed
# `uuid` in the canonical schema, so a stub identity carrying anything else is one
# the shipped tables cannot store (K-829; found by the T-088 audit-log writer, which
# K-828 has since removed — the constraint it exposed is the schema's, not that
# writer's, and outlives it).
AGENT_A = "a0000000-0000-0000-0000-000000000001"
AGENT_B = "a0000000-0000-0000-0000-000000000002"
TOKEN_A = "agent:u-#{ALICE_UUID}:a-#{AGENT_A}:r-customer"
TOKEN_B = "agent:u-#{BOB_UUID}:a-#{AGENT_B}:r-customer"

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

def bearer(token) = { "Authorization" => "Bearer #{token}" }

# ── Step 1: both principals post a listing so the board is cross-owner ────────
rc, alice_post = post_json("/kiosk/post_listing",
                           { category_slug: "furniture",
                             title: "Alice bookshelf", body: "Pine, 5-shelf", price_text: "€80" },
                           bearer(TOKEN_A))
abort "A post_listing failed (#{rc}): #{JSON.generate(alice_post)}" unless rc == 200
alice_listing_id = alice_post["listing_id"]
abort "A listing_id missing: #{JSON.generate(alice_post)}" unless alice_listing_id
STDERR.puts "  A posted listing #{alice_listing_id}"

rc, bob_post = post_json("/kiosk/post_listing",
                         { category_slug: "bikes",
                           title: "Bob mountain bike", body: "Hardtail, size L", price_text: "€500" },
                         bearer(TOKEN_B))
abort "B post_listing failed (#{rc}): #{JSON.generate(bob_post)}" unless rc == 200
bob_listing_id = bob_post["listing_id"]
abort "B listing_id missing: #{JSON.generate(bob_post)}" unless bob_listing_id
STDERR.puts "  B posted listing #{bob_listing_id}"

# ── Step 2: browse_listings is cross-owner (Assertion 1) ─────────────────────
rc, browse = get_json("/kiosk/browse_listings", {}, bearer(TOKEN_B))
abort "browse_listings failed (#{rc}): #{JSON.generate(browse)}" unless rc == 200
browse_ids = Array(browse).map { |r| r["listing_id"] }
STDERR.puts "  B browse_listings ids: #{browse_ids.inspect}"

# ── Step 3: Bob's my_listings — scoped (Assertions 2a/2b) ────────────────────
rc, bmine = get_json("/kiosk/my_listings", {}, bearer(TOKEN_B))
abort "B my_listings failed (#{rc}): #{JSON.generate(bmine)}" unless rc == 200
b_my_ids = Array(bmine).map { |r| r["listing_id"] }
STDERR.puts "  B my_listings ids: #{b_my_ids.inspect}"

# ── Step 4: Bob edit_listing on ALICE's listing → 403 (Assertion 3) ──────────
edit_rc, edit_body = post_json("/kiosk/edit_listing",
                               { listing_id: alice_listing_id, price_text: "€1" },
                               bearer(TOKEN_B))
STDERR.puts "  B edit Alice's listing → #{edit_rc}"

# ── Step 5: Bob close_listing on ALICE's listing → 403 (Assertion 4) ─────────
close_rc, close_body = post_json("/kiosk/close_listing",
                                 { listing_id: alice_listing_id },
                                 bearer(TOKEN_B))
STDERR.puts "  B close Alice's listing → #{close_rc}"

# ── Step 6: forged owner_id arg on Bob's post_listing (Assertion 5) ──────────
#
# Bob's token identifies Bob; the forged arg supplies Alice's UUID. On the 0.4
# wire this is REFUSED before the handler runs: `post_listing` publishes
# `additionalProperties: false` and does not declare `owner_id` — the principal
# is not one of its inputs — so the declared input contract answers a typed 400
# naming the parameter. (Through 0.3 the argument was accepted and silently
# ignored; refusing it is the stricter answer and the one the published
# contract requires.)
forged_rc, forged = post_json("/kiosk/post_listing",
                              { category_slug: "electronics",
                                title: "Forged owner test", body: "should belong to Bob",
                                owner_id: ALICE_UUID },
                              bearer(TOKEN_B))
STDERR.puts "  B post_listing with a forged owner_id → #{forged_rc} #{forged['code'].inspect}"

# And the second half, which the refusal does not by itself prove: ownership is
# taken from the AUTHENTICATED identity. Bob posts legitimately; the rake task
# reads the row back and asserts owner_id == Bob.
rc, legit = post_json("/kiosk/post_listing",
                      { category_slug: "electronics",
                        title: "Owner-from-token test", body: "must belong to Bob" },
                      bearer(TOKEN_B))
abort "B post_listing failed (#{rc}): #{JSON.generate(legit)}" unless rc == 200
owner_probe_listing_id = legit["listing_id"]
STDERR.puts "  B posted (owner from token): #{owner_probe_listing_id}"

puts JSON.generate(
  user_id_a:          ALICE_UUID,
  user_id_b:          BOB_UUID,
  alice_listing_id:   alice_listing_id,
  bob_listing_id:     bob_listing_id,
  browse_ids:         browse_ids,
  b_my_ids:           b_my_ids,
  cross_owner_edit:   [edit_rc, edit_body["code"]],
  cross_owner_close:  [close_rc, close_body["code"]],
  forged_refusal:     [forged_rc, forged["code"], forged["detail"]],
  owner_probe_listing_id: owner_probe_listing_id,
)
