# frozen_string_literal: true

# Red-team battery for philslist: attacks a running server and asserts every attack is refused.
# Usage: SERVER_URL=http://127.0.0.1:3006 bundle exec ruby script/redteam_suite.rb

require "json"
require "securerandom"

require "kiosk/redteam"

require_relative "bound_assistant"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = SERVER

# The seeded humans behind the two assistants (db/seeds.rb).
ALICE_EMAIL = "alice@example.com"
BOB_EMAIL   = "bob@example.com"
PASSWORD    = "philslist-demo-password"

WIRE = Kiosk::TestHelpers::Wire.new(base_url: SERVER)

BATTERY = Kiosk::Redteam::Battery.new

# Two principals, each bound through the shipped ceremony.
ALICE = bind_assistant(server: SERVER, issuer: ISSUER, email: ALICE_EMAIL, password: PASSWORD)
BOB   = bind_assistant(server: SERVER, issuer: ISSUER, email: BOB_EMAIL,   password: PASSWORD)
abort "both assistants bound to the SAME account (#{ALICE.user_id}) — no boundary to attack" \
  if ALICE.user_id == BOB.user_id

# Alice's listing, the target of the cross-owner attacks.
rc, alice_post = WIRE.post_json("/kiosk/post_listing",
                                { category_slug: "furniture",
                                  title: "Redteam target", body: "Alice's listing" },
                                ALICE.bearer)
abort "A post_listing failed (#{rc}): #{JSON.generate(alice_post)} — run bin/rails db:reset" unless rc == 200
alice_listing_id = alice_post["listing_id"]
abort "no listing_id from A's post: #{JSON.generate(alice_post)}" unless alice_listing_id

rc, b_mine = WIRE.get_json("/kiosk/my_listings", {}, BOB.bearer)
b_ids = Array(b_mine).map { |r| r["listing_id"] }
BATTERY.record("CrossTenantRead",
               rc == 200 && !b_ids.include?(alice_listing_id),
               "Bob's my_listings #{b_ids.inspect} excludes Alice's #{alice_listing_id}")

# A forged owner_id is refused (400), and Bob's own listing never lands under Alice.
rc, forged = WIRE.post_json("/kiosk/post_listing",
                            { category_slug: "free",
                              title: "Forged", body: "should be Bob's", owner_id: ALICE.user_id },
                            BOB.bearer)
refused = rc == 400 && forged["code"] == "bad_request" && forged["detail"].to_s.include?("owner_id")

rc_b, bobs = WIRE.post_json("/kiosk/post_listing",
                            { category_slug: "free", title: "Bob's own", body: "belongs to Bob" },
                            BOB.bearer)
bob_id = bobs["listing_id"]
rc_a, a_mine = WIRE.get_json("/kiosk/my_listings", {}, ALICE.bearer)
a_ids = Array(a_mine).map { |r| r["listing_id"] }
BATTERY.record("ForgedUserId",
               refused && rc_b == 200 && rc_a == 200 && !a_ids.include?(bob_id),
               "forged owner_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming owner_id); " \
               "Alice's list #{a_ids.inspect} excludes Bob's #{bob_id.inspect}")

rc, _ = WIRE.post_json("/kiosk/edit_listing",
                       { listing_id: alice_listing_id, price_text: "€1" },
                       BOB.bearer)
BATTERY.record("CrossOwnerEdit", rc == 403, "Bob edit Alice's listing → #{rc} (want 403)")

rc, _ = WIRE.post_json("/kiosk/close_listing",
                       { listing_id: alice_listing_id },
                       BOB.bearer)
BATTERY.record("CrossOwnerClose", rc == 403, "Bob close Alice's listing → #{rc} (want 403)")

# A junk listing_id is a typed 400 naming the argument, with no SQL internals on the wire.
MALFORMED_IDS = ["not-a-uuid", "1; DROP TABLE listings", "", "  "].freeze
SQL_INTERNALS = ["::uuid", "PG::", "22P02", "invalid input syntax"].freeze

# `supplied:` keeps the scan from reporting the probe's own echoed bytes as a leak.
uuid_probes = %w[edit_listing close_listing].flat_map do |verb|
  MALFORMED_IDS.map do |junk|
    args     = { listing_id: junk }
    rc, body = WIRE.post_json("/kiosk/#{verb}", args, ALICE.bearer)
    scan = Kiosk::Redteam::LeakScan.scan(body, SQL_INTERNALS, supplied: args)
    ok = rc == 400 && body["code"] == "bad_request" &&
         body["detail"].to_s.include?("listing_id") && !scan.leak?
    [ok, "#{verb}(#{junk.inspect})→#{rc}/#{body['code'].inspect}" \
         "#{scan.leak ? " LEAK #{scan.leak}" : ''}#{scan.note}"]
  end
end
BATTERY.record("MalformedUuidArg", uuid_probes.all? { |ok, _| ok },
               "malformed listing_id → #{uuid_probes.map(&:last).join(', ')} " \
               "(want 400/\"bad_request\", a detail naming listing_id, and no SQL internals)")

rc, _ = WIRE.get_json("/kiosk/browse_listings")
BATTERY.record("MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")

rc, _ = WIRE.get_json("/kiosk/browse_listings", {}, WIRE.bearer("not-a-real-token"))
BATTERY.record("GarbageToken", rc == 401, "garbage token → #{rc} (want 401)")

# A self-asserted bearer naming a real account buys nothing; Alice's bound token is the control.
forged_bearer = WIRE.bearer("agent:u-#{ALICE.user_id}:a-#{SecureRandom.uuid}:r-owner")
rc_forged_read, = WIRE.get_json("/kiosk/my_listings", {}, forged_bearer)
rc_forged_write, = WIRE.post_json("/kiosk/post_listing",
                                  { category_slug: "free", title: "Self-asserted", body: "must never exist" },
                                  forged_bearer)
rc_real_read,  = WIRE.get_json("/kiosk/my_listings", {}, ALICE.bearer)
rc_real_write, = WIRE.post_json("/kiosk/post_listing",
                                { category_slug: "free", title: "Really Alice's", body: "bound token" },
                                ALICE.bearer)
BATTERY.record("SelfAssertedTokenForgery",
               rc_forged_read == 401 && rc_forged_write == 401 &&
                 rc_real_read == 200 && rc_real_write == 200,
               "self-asserted `agent:u-…:a-…:r-owner` naming a real account → read #{rc_forged_read}, " \
               "write #{rc_forged_write} (want 401/401: it resolves to NO identity, in THIS environment — " \
               "no env gate involved); CONTROL Alice's genuinely-bound token → read #{rc_real_read}, " \
               "write #{rc_real_write} (want 200/200, so the refusal is not vacuous)")

rc, _ = WIRE.get_json("/kiosk/frobnicate", {}, ALICE.bearer)
BATTERY.record("UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")

rc, _ = WIRE.post_json("/kiosk/nope", {}, ALICE.bearer)
BATTERY.record("UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# /kiosk/query and /kiosk/run are plain 404s, with or without a bearer.
unregistered = %w[query run].flat_map do |name|
  authed = WIRE.request(:post, "/kiosk/#{name}", body: { name: "browse_listings" }, headers: ALICE.bearer)
  anon   = WIRE.request(:post, "/kiosk/#{name}", body: { name: "browse_listings" })
  [[authed.status == 404 && authed.body["code"].nil?, "#{name}→#{authed.status}"],
   [anon.status   == 404 && anon.body["code"].nil?,   "#{name}(anon)→#{anon.status}"]]
end
BATTERY.record("UnregisteredVerbIsOrdinaryRefusal",
               unregistered.all? { |ok, _| ok },
               "unregistered verb names #{unregistered.map(&:last).join(', ')} " \
               "(want a plain 404 with no problem-document code, bearer or not)")

# A GET at an action's path is a plain 404 and never reaches the action.
res404 = WIRE.request(:get, "/kiosk/post_listing", headers: ALICE.bearer)
BATTERY.record("MethodMismatch",
               res404.status == 404 && res404["allow"].nil? && res404.body["code"].nil?,
               "GET an action → #{res404.status} Allow=#{res404['allow'].inspect} " \
               "(want a plain 404, no Allow, no problem-document code)")

# An unknown category is refused naming the live categories, never clamped to a default.
rc_bad, bad_status = WIRE.get_json("/kiosk/browse_listings", { category_slug: "no-such-section" }, ALICE.bearer)
detail_bad = bad_status.is_a?(Hash) ? bad_status["detail"].to_s : ""
rc_ctl, ctl_rows = WIRE.get_json("/kiosk/browse_listings", { category_slug: "bikes" }, ALICE.bearer)
BATTERY.record("OutOfEnumFilterIsNotSilentlyReinterpreted",
               rc_bad == 400 && bad_status["code"] == "bad_request" &&
                 detail_bad.include?("bikes") && detail_bad.include?("housing") &&
                 rc_ctl == 200 && ctl_rows.is_a?(Array),
               "category_slug=no-such-section → #{rc_bad}/#{bad_status['code'].inspect} " \
               "detail=#{detail_bad[0, 160].inspect}; " \
               "CONTROL category_slug=bikes → #{rc_ctl}/#{ctl_rows.is_a?(Array) ? "array" : ctl_rows.class} " \
               "(want 400 bad_request naming the LIVE categories, and an ANSWERED control)")

# `_` in a keyword matches only an underscore, not any character.
_, wild_rows = WIRE.get_json("/kiosk/browse_listings", { keyword: "b_ke" }, ALICE.bearer)
rc_lit, lit_rows = WIRE.get_json("/kiosk/browse_listings", { keyword: "bike" }, ALICE.bearer)
BATTERY.record("LikeMetacharactersAreEscaped",
               wild_rows.is_a?(Array) && wild_rows.empty? &&
                 rc_lit == 200 && lit_rows.is_a?(Array) && !lit_rows.empty?,
               "keyword=b_ke → #{wild_rows.is_a?(Array) ? "#{wild_rows.length} rows" : wild_rows.class}; " \
               "CONTROL keyword=bike → #{rc_lit}/#{lit_rows.is_a?(Array) ? "#{lit_rows.length} rows" : lit_rows.class} " \
               "(want 0 rows for the escaped wildcard and a non-empty control)")

# Read as Bob, the open board shows one `seller-` pseudonym per seller and no account address.
rc_board, board_rows = WIRE.get_json("/kiosk/browse_listings", {}, BOB.bearer)
raw_board = JSON.generate(board_rows)
rows          = board_rows.is_a?(Array) ? board_rows : []
handles       = rows.map { |r| r["owner_handle"] }
alice_handle  = rows.find { |r| r["listing_id"] == alice_listing_id }&.fetch("owner_handle", nil)
bob_handle    = rows.find { |r| r["listing_id"] == bob_id }&.fetch("owner_handle", nil)
alice_rows    = rows.count { |r| r["owner_handle"] == alice_handle }
no_addresses  = !raw_board.include?(ALICE_EMAIL) && !raw_board.include?(BOB_EMAIL) && !raw_board.include?("@example.com")
well_formed   = !handles.empty? && handles.all? { |h| h.is_a?(String) && h.match?(/\Aseller-[0-9a-f]{12}\z/) }
per_seller    = !alice_handle.nil? && !bob_handle.nil? &&
                alice_handle != bob_handle && alice_rows >= 2
BATTERY.record("NoSellerPiiOnTheOpenBoard",
               rc_board == 200 && no_addresses && well_formed && per_seller,
               "browse_listings as BOB → #{rc_board}, #{rows.length} rows, " \
               "#{handles.uniq.length} distinct handles #{handles.uniq.first(3).inspect}; " \
               "account addresses in body: #{no_addresses ? 'none' : 'FOUND'}; " \
               "alice=#{alice_handle.inspect} on #{alice_rows} rows, bob=#{bob_handle.inspect} " \
               "(want 200, no account address anywhere, every handle an opaque " \
               "`seller-<12 hex>`, and ONE handle covering >= 2 of Alice's rows and not Bob's)")

# A contact line in post_listing's body is masked in the request log; the unfiltered title is the control.
body_sentinel  = "contact-#{SecureRandom.hex(8)}"
title_sentinel = "title-#{SecureRandom.hex(8)}"
rc_log, _log_post = WIRE.post_json("/kiosk/post_listing",
                                   { category_slug: "free",
                                     title: "Redteam #{title_sentinel}",
                                     body:  "Call me on #{body_sentinel}" },
                                   ALICE.bearer)
request_log  = File.expand_path("../log/development.log", __dir__)
log_text     = File.exist?(request_log) ? File.read(request_log, encoding: "UTF-8", invalid: :replace, undef: :replace) : ""
param_lines  = log_text.each_line.select { |line| line.include?("Parameters:") }
body_logged  = param_lines.any? { |line| line.include?(body_sentinel) }
title_logged = param_lines.any? { |line| line.include?(title_sentinel) }
BATTERY.record("ContactDetailsStayOutOfTheRequestLog",
               rc_log == 200 && title_logged && !body_logged,
               "post_listing → #{rc_log}; across #{param_lines.length} `Parameters:` line(s) in " \
               "#{File.basename(request_log)} the body sentinel is #{body_logged ? 'FOUND' : 'absent'} and the " \
               "title sentinel is #{title_logged ? 'found' : 'MISSING'} " \
               "(want 200, the contact line masked on every one of them, and the unfiltered title present)")

# The shared kiosk-redteam beat; this origin declares a role, so a skip is a breach.
BATTERY.scenario(
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  client:  Kiosk::TestHelpers::Assistant.new(base_url: SERVER),
  profile: Kiosk::Redteam::Profile.new(pow_difficulty: 1, declared_roles: %w[customer]),
  on_skip: :breach,
)

exit BATTERY.report!
