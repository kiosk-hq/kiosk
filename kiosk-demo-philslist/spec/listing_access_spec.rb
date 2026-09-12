# frozen_string_literal: true

# Standalone (no rails boot, no DB) unit spec for {ListingAccess} — the two
# sentences philslist's owner-scoped verbs share — and for the {OperationResult}
# status map they resolve through. Run with:
#   bundle exec rake demo:access_spec   (or: ruby spec/listing_access_spec.rb)
#
# WHY IT IS DB-FREE, AND WHY IT CAN BE. This module is the whole of the
# owner-scoped refusal surface and NOTHING in it touches a table: `edit_listing`
# and `close_listing` ask it for the shape of a `listing_id` and for the
# sentence a miss earns, then do their own single-statement update. So the part
# an assistant actually branches on — the code, the status, the sentence, the
# hint — is a pure function, and the only executable coverage it had needed a
# seeded Postgres, a booted server and a Python solver to reach.
#
# WHAT THE TWO SENTENCES ARE FOR, because the assertions below are about
# exactly that and not about «something was refused»:
#
#   • THE SHAPE REFUSAL. ActiveRecord does not refuse a malformed uuid, it CASTS
#     it to NULL, which matches no row — so without the check in front, a typo
#     would come back as an OWNERSHIP refusal and the caller would go hunting
#     for a permission problem that is not there. A malformed id is a client
#     mistake and has to read as one.
#   • THE OWNER-SCOPED MISS. «No such listing» and «not yours» are deliberately
#     ONE answer. Splitting them would let a caller enumerate other owners'
#     listing ids by asking, which is why there is no `not_found` in the status
#     map and must not be.
#
# WHAT IS DELIBERATELY NOT HERE. The row count that DECIDES the miss —
# `Listing.owned_by_current_principal.where(id:).update_all(…)`, whose WHERE is
# `owner_id = kiosk.current_user_id()` against a transaction-local GUC — is not
# a pure function and must not be faked into one: what makes it un-bypassable is
# that the principal comes from the database session rather than from an
# argument. `demo:isolation` and `demo:redteam` drive it against a real
# Postgres. This file covers the answer that decision earns.

require "active_support"
require "active_support/core_ext/object/blank"
require "kiosk/uuid_check"
require "kiosk/operation_result"

require_relative "../app/operations/operation_result"
require_relative "../app/operations/listing_access"

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

# Call a guard and never let it raise past this line: a raise IS the defect this
# module exists to prevent — a hostile shape reaching the database, or a refusal
# that cannot be rendered — so it is recorded as a failed assertion rather than
# ending the run at the first one.
def guard(label)
  yield
rescue StandardError => e
  FAILURES << "#{label} RAISED #{e.class}: #{e.message}"
  puts "  FAIL  #{label} RAISED #{e.class}: #{e.message}"
  nil
end

# Every refusal here is an {OperationResult} carrying a wire `code` that
# philslist's own STATUSES map resolves. Asserted per refusal rather than
# described once in prose: a code this app never mapped raises a KeyError here
# rather than at the wire.
def assert_refusal(result, label, code:, status:)
  unless result.is_a?(OperationResult)
    return assert(false, "#{label} → an OperationResult, got #{result.class}")
  end

  assert(!result.ok?, "#{label} → a refusal, not an answer")
  assert(result.code == code, "#{label} → code #{code.inspect}, got #{result.code.inspect}")
  resolved = guard("#{label} status") { result.status }
  assert(resolved == status, "#{label} → status #{status.inspect}, got #{resolved.inspect}")
end

puts "\n── the owner-scoped refusal surface, with no database under it ──"

# ── 0. THE SUBJECT IS ACTUALLY HERE (this spec never no-ops) ────────────────
assert(defined?(ListingAccess) && ListingAccess.respond_to?(:listing_id),
       "ListingAccess.listing_id is loaded")
assert(ListingAccess.respond_to?(:not_owner), "ListingAccess.not_owner is loaded")
assert(!defined?(Listing),
       "…and Listing is NOT loaded, so nothing below can reach a table even by accident")

# ── 1. A WELL-FORMED ID IS PASSED THROUGH VERBATIM ──────────────────────────
#
# Verbatim and not normalised: the id the caller sent is the id echoed back in
# the answer, and it is never read out of the database. `Kiosk::UuidCheck`
# accepts either case because Postgres' `uuid` compares canonically, so an id
# shouted back in capitals is the same row — and lower-casing it here would be
# this module inventing a canonical form of its own.
["9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f",
 "9C1D2E3F-4A5B-4C6D-8E7F-0A1B2C3D4E5F",
 "9c1D2e3F-4a5B-4c6D-8e7F-0a1B2c3D4e5F"].each do |ok|
  id, refusal = guard("listing_id(#{ok.inspect})") { ListingAccess.listing_id(ok) } || [nil, nil]
  assert(refusal.nil?, "#{ok} is accepted as a listing_id")
  assert(id == ok, "…and comes back byte-for-byte as it arrived, got #{id.inspect}")
end

# ── 2. EVERY OTHER SHAPE IS A TYPED 400 THAT NAMES THE VALUE ────────────────
#
# The refusal has to be legible without the schema: a caller reading
# `listing_id "9c1d…" is not a uuid` can see what it sent, and the hint says
# where a good one comes from.
[nil, "", "not-a-uuid", 12_345, true, [], {},
 "{9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f}",
 "urn:uuid:9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f",
 "9c1d2e3f4a5b4c6d8e7f0a1b2c3d4e5f",
 "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5",
 "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5ff",
 "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5g",
 " 9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f",
 "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f "].each do |bad|
  id, refusal = guard("listing_id(#{bad.inspect})") { ListingAccess.listing_id(bad) } || [nil, nil]
  assert(id.nil?, "#{bad.inspect} yields no id to act on, got #{id.inspect}")
  assert_refusal(refusal, "listing_id(#{bad.inspect})", code: "bad_request", status: :bad_request)
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "listing_id #{bad.to_s.inspect} is not a uuid",
         "…and the sentence names the value it refused: #{refusal.message.inspect}")
  assert(refusal.hint.to_s.include?("my_listings"),
         "…and the hint says where a good one comes from: #{refusal.hint.inspect}")
  assert(!refusal.message.match?(/PG::|SQLSTATE|invalid input syntax/),
         "…and leaks no database internals")
end

# An omitted `listing_id` is not a distinct case and must not read as one:
# `listing_id` is `required` in both descriptors but nothing at the wire enforces
# that, so it arrives as nil and gets the empty-string sentence. Stated as an
# assertion because it is the refusal a caller is most likely to meet.
_, omitted = guard("listing_id(nil) sentence") { ListingAccess.listing_id(nil) } || [nil, nil]
assert(omitted.is_a?(OperationResult) && omitted.message == 'listing_id "" is not a uuid',
       "an omitted listing_id reads as the empty one, not as a crash")

# ── 3. THE OWNER-SCOPED MISS IS ONE ANSWER FOR TWO SITUATIONS ───────────────
#
# This is the assertion the enumeration argument rests on. A listing that does
# not exist and a listing belonging to somebody else earn the SAME sentence, so
# a caller that walks id after id learns nothing about which of them are real.
edit  = guard("not_owner(edit)")  { ListingAccess.not_owner("edit") }
close = guard("not_owner(close)") { ListingAccess.not_owner("close") }
assert_refusal(edit,  "not_owner(edit)",  code: "forbidden", status: :forbidden)
assert_refusal(close, "not_owner(close)", code: "forbidden", status: :forbidden)
assert(edit.is_a?(OperationResult) &&
       edit.message == "listing not owned by the authenticated principal",
       "…the miss says «not owned», got #{edit&.message.inspect}")
assert(edit.is_a?(OperationResult) && close.is_a?(OperationResult) &&
       edit.message == close.message,
       "…and BOTH verbs say exactly the same thing, so ids cannot be enumerated by asking")
assert(edit.is_a?(OperationResult) && !edit.message.match?(/exist|found|missing|unknown/i),
       "…the sentence does not hint at existence either way: #{edit&.message.inspect}")

# The HINT is the one part that may differ, because it names what the caller was
# trying to do rather than what the board knows about the row.
assert(edit.is_a?(OperationResult) && edit.hint == "You may only edit your own listings.",
       "the hint names the attempted verb, got #{edit&.hint.inspect}")
assert(close.is_a?(OperationResult) && close.hint == "You may only close your own listings.",
       "…and the other verb gets its own, got #{close&.hint.inspect}")

# ── 4. THE TWO REFUSALS ARE DIFFERENT ANSWERS ───────────────────────────────
#
# The whole reason the shape check exists: a typo must not be reported as an
# ownership problem. Written as one assertion so a future guard that folded the
# two together could not pass here.
_, shape = guard("listing_id(junk)") { ListingAccess.listing_id("not-a-uuid") } || [nil, nil]
assert(shape.is_a?(OperationResult) && edit.is_a?(OperationResult) &&
       shape.code != edit.code,
       "a malformed id and a foreign one are different codes: " \
       "#{shape&.code.inspect} vs #{edit&.code.inspect}")
assert(shape.is_a?(OperationResult) && edit.is_a?(OperationResult) &&
       shape.status != edit.status,
       "…and different statuses: #{shape&.status.inspect} vs #{edit&.status.inspect}")

# ── 5. THE STATUS MAP IS THIS APP'S OWN, AND IT HAS NO `not_found` ──────────
#
# Two codes, because philslist's writes make two refusals. The absence of
# `not_found` is a decision rather than an omission — it is the same
# no-enumeration argument as section 3, written into the table — so it is
# asserted rather than left to be noticed.
assert(OperationResult::STATUSES == { "bad_request" => :bad_request, "forbidden" => :forbidden },
       "the map is exactly the two codes philslist refuses with, got " \
       "#{OperationResult::STATUSES.inspect}")
assert(OperationResult::STATUSES.frozen?, "…and it is frozen")
assert(!OperationResult::STATUSES.key?("not_found"),
       "…and carries no `not_found`, because a missing listing and a foreign one answer alike")
unmapped = OperationResult.refused(code: "not_found", message: "…")
raised = begin
  unmapped.status
  false
rescue KeyError
  true
end
assert(raised, "refusing with an unmapped code raises a KeyError at the seam rather than " \
               "guessing a status")

if FAILURES.empty?
  puts "\n  listing-access spec: all assertions passed"
  exit 0
else
  puts "\n  listing-access spec: #{FAILURES.length} FAILED"
  FAILURES.each { |f| puts "    - #{f}" }
  exit 1
end
