# frozen_string_literal: true

# Standalone (no rails boot, no DB) unit spec for {ListAccess} — the
# precondition every list-scoped caller in this demo shares — and for the
# {OperationResult} status map its refusals resolve through. Run with:
#   bundle exec rake check:access_spec   (or: ruby spec/list_access_spec.rb)
#
# WHY IT IS DB-FREE. {ListAccess} is a two-step gate and only the SECOND step
# reads a table. Step one is a regexp over the wire value; step two asks
# {Membership.reachable?}, which is the DECISION, and this module turns that
# decision into the sentence a caller is told. The sentence is what the wire
# publishes and the sentence is what an assistant branches on, so it is worth
# asserting on its own — and asserting it needs no rows, only a decision to
# stand in for the one the database would have made.
#
# HOW THE DECISION IS STOOD IN FOR. Sections 2 onward install a {Membership}
# whose `reachable?` answers a scripted value and records how it was called. No
# database, no schema, no transaction to leak on a crash — and the code under
# test is reached exactly as the wire reaches it, because {ListAccess} calls
# that one method and nothing else.
#
# THE FIRST SECTION INSTALLS NOTHING, ON PURPOSE. `Membership` does not exist
# yet while the shape refusals run, so a guard that consulted the table before
# checking the shape would raise a NameError and be recorded as a failure by
# name. That is the property the whole module hangs on: ActiveRecord does not
# refuse a malformed uuid, it CASTS it to NULL, which matches no row — so
# without the shape check first, a typo would be reported as an ACCESS refusal
# rather than as the client mistake it is, and the caller would go looking for
# a permission problem that is not there.
#
# WHAT IS DELIBERATELY NOT HERE. {Membership.reachable?} itself — the SQL
# predicate reading `kiosk.current_user_id()` out of a transaction-local GUC —
# is not a pure function and must not be faked into one: what makes it
# un-bypassable is that the principal comes from the database session rather
# than from an argument, and nothing a unit spec can set up would exercise that.
# `check:isolation` and `check:redteam` drive it against a real Postgres.

require "active_support"
require "active_support/core_ext/object/blank"
require "kiosk/uuid_check"
require "kiosk/operation_result"

require_relative "../app/operations/operation_result"
require_relative "../app/operations/list_access"

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

# Call the gate and never let it raise past this line. A raise here is the
# defect — a hostile shape that reaches the database, or a refusal that cannot
# be rendered — so it is recorded as a failed assertion rather than ending the
# run at the first one.
def guard(label)
  yield
rescue StandardError => e
  FAILURES << "#{label} RAISED #{e.class}: #{e.message}"
  puts "  FAIL  #{label} RAISED #{e.class}: #{e.message}"
  nil
end

# Every refusal this module makes is an {OperationResult} carrying a wire `code`
# that tudu's own STATUSES map resolves. Asserted per refusal rather than
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

VALID_UUID = "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f"

puts "\n── the list-access gate, with no database under it ──"

# ── 0. THE SUBJECT IS ACTUALLY HERE (this spec never no-ops) ────────────────
assert(defined?(ListAccess) && ListAccess.respond_to?(:check), "ListAccess.check is loaded")
assert(!defined?(Membership),
       "…and Membership is NOT loaded, so section 1 below cannot reach a table even by accident")

# ── 1. SHAPE FIRST, AND THE TABLE IS NOT CONSULTED ──────────────────────────
#
# Each of these is a 400 naming the value, and each of them is answered with no
# {Membership} in the world. Both halves matter: the CODE, because a malformed
# id is a client mistake and not an ownership one, and the ORDER, because a gate
# that asked the table first would answer 403 for a typo.
[nil, "", "not-a-uuid", 12_345, true,
 "{9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f}",
 "urn:uuid:9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f",
 "9c1d2e3f4a5b4c6d8e7f0a1b2c3d4e5f",
 "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5",
 "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5ff",
 " 9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f",
 "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5g"].each do |raw|
  refusal = guard("check(#{raw.inspect})") { ListAccess.check(raw) }
  assert_refusal(refusal, "check(#{raw.inspect})", code: "bad_request", status: :bad_request)
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "list_id #{raw.to_s.inspect} is not a uuid",
         "…and the sentence names the value it refused: #{refusal.message.inspect}")
  assert(refusal.hint.to_s.include?("my_lists"),
         "…and the hint says where a good one comes from: #{refusal.hint.inspect}")
end

# An omitted `list_id` is not a distinct case and must not read as one: nothing
# at the wire enforces `required`, so it arrives as nil and gets the empty-string
# sentence above. Stated as an assertion because it is the one refusal a caller
# is most likely to meet.
omitted = guard("check(nil) sentence") { ListAccess.check(nil) }
assert(omitted.is_a?(OperationResult) && omitted.message == 'list_id "" is not a uuid',
       "an omitted list_id reads as the empty one, not as a crash")

# ── 2. THE DECISION, STOOD IN FOR ───────────────────────────────────────────
membership = Module.new do
  class << self
    attr_accessor :answer, :calls
  end
  self.answer = false
  self.calls  = []

  def self.reachable?(list_id, require_owner: false)
    calls << { list_id: list_id, require_owner: require_owner }
    answer
  end
end
Object.const_set(:Membership, membership)

# ── 3. A MEMBER IS LET THROUGH, AND «let through» IS `nil` ──────────────────
#
# The gate answers a REFUSAL or nothing at all. It never answers a truthy
# success object, because every caller is written as `return refusal if refusal`
# — three kinds of caller, none of which render the same way.
Membership.answer = true
Membership.calls  = []
granted = guard("check(a reachable list)") { ListAccess.check(VALID_UUID) }
assert(granted.nil?, "a member is refused nothing, and «nothing» is nil, got #{granted.inspect}")
assert(Membership.calls.length == 1 && Membership.calls.first[:list_id] == VALID_UUID,
       "…the id reaches the decision verbatim, got #{Membership.calls.inspect}")
assert(Membership.calls.first[:require_owner] == false,
       "…and an ordinary member check does not silently demand ownership")

# ── 4. A NON-MEMBER GETS 403, NOT 404 ───────────────────────────────────────
#
# Deliberately Forbidden and not NotFound: a caller that could tell «no such
# list» from «not yours» could enumerate which list ids exist by asking.
Membership.answer = false
Membership.calls  = []
foreign = guard("check(a foreign list)") { ListAccess.check(VALID_UUID) }
assert_refusal(foreign, "check(a foreign list)", code: "forbidden", status: :forbidden)
assert(foreign.is_a?(OperationResult) &&
       foreign.message == "list not accessible by the authenticated principal",
       "…with the member sentence, got #{foreign&.message.inspect}")
assert(foreign.is_a?(OperationResult) && foreign.hint.to_s.include?("member of"),
       "…and a hint that says what would have worked, got #{foreign&.hint.inspect}")

# THE SHAPE REFUSAL AND THE ACCESS REFUSAL ARE DIFFERENT ANSWERS, and this is
# the assertion the whole module exists for: with the decision answering «no» to
# everything, a MALFORMED id must still come back 400 rather than being folded
# into the 403. A caller told the wrong one debugs the wrong thing.
malformed_still_400 = guard("check(junk) while the decision says no") { ListAccess.check("not-a-uuid") }
assert(malformed_still_400.is_a?(OperationResult) && malformed_still_400.code == "bad_request",
       "a malformed id is a client mistake even when nothing would be reachable, got " \
       "#{malformed_still_400&.code.inspect}")
assert(Membership.calls.length == 1,
       "…and the decision was not asked about it — #{Membership.calls.length} call(s) since the " \
       "foreign-list check, want 1")

# ── 5. OWNER-ONLY IS A DIFFERENT DEMAND AND A DIFFERENT SENTENCE ────────────
#
# `invite` and `remove_member` tighten the same gate to role='owner'. Two things
# have to hold: the demand is FORWARDED to the decision, and the refusal says
# «not owned» rather than «not accessible» — a member who is not the owner is
# not being told they are a stranger to the list.
Membership.answer = false
Membership.calls  = []
not_owner = guard("check(require_owner: true)") { ListAccess.check(VALID_UUID, require_owner: true) }
assert(Membership.calls.first&.fetch(:require_owner, nil) == true,
       "the owner demand reaches the decision, got #{Membership.calls.inspect}")
assert_refusal(not_owner, "check(require_owner: true)", code: "forbidden", status: :forbidden)
assert(not_owner.is_a?(OperationResult) &&
       not_owner.message == "list not owned by the authenticated principal",
       "…with the OWNER sentence, got #{not_owner&.message.inspect}")
assert(not_owner.is_a?(OperationResult) && not_owner.hint.to_s.include?("owner"),
       "…and an owner-shaped hint, got #{not_owner&.hint.inspect}")
assert(not_owner.is_a?(OperationResult) && foreign.is_a?(OperationResult) &&
       not_owner.message != foreign.message,
       "the two refusals are DIFFERENT sentences — «not owned» is not «not accessible»")
assert(not_owner.is_a?(OperationResult) && foreign.is_a?(OperationResult) &&
       not_owner.hint != foreign.hint,
       "…and so are their hints")

# An owner IS let through the tightened gate, so the demand is a filter and not
# a refusal in disguise.
Membership.answer = true
Membership.calls  = []
assert(guard("check(owner, require_owner: true)") { ListAccess.check(VALID_UUID, require_owner: true) }.nil?,
       "an owner passes the tightened gate")

# ── 6. THE STATUS MAP IS THIS APP'S OWN, AND IT IS SHORT ON PURPOSE ─────────
#
# Two codes, because tudu's writes make two refusals. A code this app never
# produces has no mapping, and `fetch` turning a typo into a loud KeyError is
# the point of writing the table out rather than deriving it.
assert(OperationResult::STATUSES == { "bad_request" => :bad_request, "forbidden" => :forbidden },
       "the map is exactly the two codes tudu refuses with, got #{OperationResult::STATUSES.inspect}")
assert(OperationResult::STATUSES.frozen?, "…and it is frozen")
unmapped = OperationResult.refused(code: "not_found", message: "…")
raised = begin
  unmapped.status
  false
rescue KeyError
  true
end
assert(raised, "an unmapped code raises a KeyError at the seam rather than guessing a status")

if FAILURES.empty?
  puts "\n  list-access spec: all assertions passed"
  exit 0
else
  puts "\n  list-access spec: #{FAILURES.length} FAILED"
  FAILURES.each { |f| puts "    - #{f}" }
  exit 1
end
