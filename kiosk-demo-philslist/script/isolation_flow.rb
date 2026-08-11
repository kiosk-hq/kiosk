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
#   5  Forged owner_id arg on Bob's post_listing is IGNORED — the created
#      listing's DB owner_id == Bob (verified via psql in the rake task).
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

TOKEN_A = "agent:u-#{ALICE_UUID}:a-alice-isolation:r-customer"
TOKEN_B = "agent:u-#{BOB_UUID}:a-bob-isolation:r-customer"

def post_json(path, body, headers = {})
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def bearer(token) = { "Authorization" => "Bearer #{token}" }

# ── Step 1: both principals post a listing so the board is cross-owner ────────
rc, alice_post = post_json("/kiosk/run",
                           { name: "post_listing", category_slug: "furniture",
                             title: "Alice bookshelf", body: "Pine, 5-shelf", price_text: "€80" },
                           bearer(TOKEN_A))
abort "A post_listing failed (#{rc}): #{JSON.generate(alice_post)}" unless rc == 200
alice_listing_id = alice_post.dig("value", "listing_id")
abort "A listing_id missing: #{JSON.generate(alice_post)}" unless alice_listing_id
STDERR.puts "  A posted listing #{alice_listing_id}"

rc, bob_post = post_json("/kiosk/run",
                         { name: "post_listing", category_slug: "bikes",
                           title: "Bob mountain bike", body: "Hardtail, size L", price_text: "€500" },
                         bearer(TOKEN_B))
abort "B post_listing failed (#{rc}): #{JSON.generate(bob_post)}" unless rc == 200
bob_listing_id = bob_post.dig("value", "listing_id")
abort "B listing_id missing: #{JSON.generate(bob_post)}" unless bob_listing_id
STDERR.puts "  B posted listing #{bob_listing_id}"

# ── Step 2: browse_listings is cross-owner (Assertion 1) ─────────────────────
rc, browse = post_json("/kiosk/query", { name: "browse_listings" }, bearer(TOKEN_B))
abort "browse_listings failed (#{rc}): #{JSON.generate(browse)}" unless rc == 200
browse_ids = (browse["rows"] || []).map { |r| r["listing_id"] }
STDERR.puts "  B browse_listings ids: #{browse_ids.inspect}"

# ── Step 3: Bob's my_listings — scoped (Assertions 2a/2b) ────────────────────
rc, bmine = post_json("/kiosk/query", { name: "my_listings" }, bearer(TOKEN_B))
abort "B my_listings failed (#{rc}): #{JSON.generate(bmine)}" unless rc == 200
b_my_ids = (bmine["rows"] || []).map { |r| r["listing_id"] }
STDERR.puts "  B my_listings ids: #{b_my_ids.inspect}"

# ── Step 4: Bob edit_listing on ALICE's listing → 403 (Assertion 3) ──────────
edit_rc, edit_body = post_json("/kiosk/run",
                               { name: "edit_listing", listing_id: alice_listing_id, price_text: "€1" },
                               bearer(TOKEN_B))
STDERR.puts "  B edit Alice's listing → #{edit_rc}"

# ── Step 5: Bob close_listing on ALICE's listing → 403 (Assertion 4) ─────────
close_rc, close_body = post_json("/kiosk/run",
                                 { name: "close_listing", listing_id: alice_listing_id },
                                 bearer(TOKEN_B))
STDERR.puts "  B close Alice's listing → #{close_rc}"

# ── Step 6: forged owner_id arg on Bob's post_listing (Assertion 5) ──────────
# Bob's token identifies Bob. The forged owner_id arg supplies Alice's UUID.
# post_listing ignores args[:owner_id] and reads kiosk.current_user_id() — the
# created listing must belong to Bob. Verified by psql SELECT in the rake task.
rc, forged = post_json("/kiosk/run",
                       { name: "post_listing", category_slug: "electronics",
                         title: "Forged owner test", body: "should belong to Bob",
                         owner_id: ALICE_UUID },
                       bearer(TOKEN_B))
abort "B forged post_listing failed (#{rc}): #{JSON.generate(forged)}" unless rc == 200
forged_listing_id = forged.dig("value", "listing_id")
STDERR.puts "  B posted (forged owner_id): #{forged_listing_id}"

puts JSON.generate(
  user_id_a:          ALICE_UUID,
  user_id_b:          BOB_UUID,
  alice_listing_id:   alice_listing_id,
  bob_listing_id:     bob_listing_id,
  browse_ids:         browse_ids,
  b_my_ids:           b_my_ids,
  cross_owner_edit:   [edit_rc, edit_body["code"] || edit_body["error"]],
  cross_owner_close:  [close_rc, close_body["code"] || close_body["error"]],
  forged_listing_id:  forged_listing_id,
)
