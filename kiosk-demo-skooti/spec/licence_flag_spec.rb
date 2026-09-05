# frozen_string_literal: true

# THE STANDING ASSERTION FOR THE LICENCE GATE'S FAIL-CLOSED PROPERTY.
#
#   bundle exec rails runner spec/licence_flag_spec.rb
#
# `rake demo:kyc` runs it first, before it boots anything, so the property is
# checked on every CI run of the demo whose motorcycle it protects.
#
# WHAT IT IS FOR. `reserve` is open to every vehicle, so unless BOTH rental
# verbs carry a licence predicate an agent can reserve the KYC-gated motorcycle
# and activate it through `start_rental`, getting a signed unlock token having
# attested nothing. The predicate itself is the second trap: enumerate the
# truthy spellings by hand — `x == true || x == "t" || x == "true"` — and every
# spelling not enumerated fails OPEN. That enumeration is correct against
# today's pg adapter, which decodes a boolean column to a real Ruby boolean,
# and wrong the moment anything changes it: one adapter, cast or schema change
# yielding `"TRUE"` or `1`, and the unrecognised value reads as licence-FREE.
#
# WHY THE REDTEAM BATTERY IS NOT THIS ASSERTION, which is the whole reason this
# file exists. `demo:redteam`'s MotorcycleViaStartRental beat drives the real
# wire against the real schema, so it only ever presents the gate with a real
# Ruby boolean — the one input on which the broken enumeration and the correct
# cast AGREE. Revert {Scooter#licence_flag} to the old chain and that beat
# still reports 23 BLOCKED / 0 BREACH. It proves the gate is wired; it cannot
# prove the gate is fail-closed, and the two are different claims.
#
# HOW IT PRESENTS THE HOSTILE VALUE. The scenario the row is about is "the
# column stopped answering with a Ruby boolean", so the probe overrides
# `needs_licence` on ONE object and reads the predicates through it. No DB, no
# schema surgery, no rollback to leak on a crash — and it reaches the same code
# the wire reaches, because both gates call these two methods and nothing else.
#
# THE SECOND HALF, and it is not optional: a predicate nobody calls proves
# nothing, so the two gate files are read here too and must still ask
# {Scooter#licence_free?} / {Scooter#licence_required?}. Without it, deleting
# the calls and re-inlining a hand-rolled test in the operations would leave
# this file green.

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK    #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

# One Scooter whose `needs_licence` answers `raw` — an unallocated instance, so
# nothing here touches the database or the column's declared type.
def vehicle_reading(raw)
  Scooter.allocate.tap { |s| s.define_singleton_method(:needs_licence) { raw } }
end

puts "\n── the licence gate is fail-closed for every spelling ──"

# ── 0. the thing under test is actually here (this spec never no-ops) ────────
assert(defined?(Scooter) && Scooter.respond_to?(:table_name), "Scooter is loaded")
assert(Scooter.instance_methods.include?(:licence_free?), "Scooter#licence_free? exists")
assert(Scooter.instance_methods.include?(:licence_required?), "Scooter#licence_required? exists")

# ── 1. TRUTHY-BUT-NOT-BOOLEAN: start_rental must stay SHUT ───────────────────
#
# This is the row's own sentence — "a non-boolean truthy spelling still
# BLOCKS". Each of these was let through by the hand-rolled chain, which is
# what made the KYC-gated motorcycle startable through the licence-free verb.
TRUTHY = ["TRUE", "True", "t", "true", "yes", "y", "on", "1", 1, 2, "Y", "ON"].freeze

TRUTHY.each do |raw|
  v = vehicle_reading(raw)
  assert(v.licence_free? == false,
         "needs_licence #{raw.inspect} is NOT licence-free (start_rental stays shut)")
  assert(v.licence_required? == true,
         "needs_licence #{raw.inspect} IS licence-required (rent_motorcycle demands KYC)")
end

# ── 2. FALSY spellings: the motorcycle verb must stay SHUT ───────────────────
#
# The other direction of the same property. `0` and `"0"` are in Rails
# FALSE_VALUES, so they read licence-FREE — stated here as an assertion rather
# than left implicit, because that is a real decision about a real gate.
FALSY = [false, "f", "false", "FALSE", "0", 0, "off", "OFF"].freeze

FALSY.each do |raw|
  v = vehicle_reading(raw)
  assert(v.licence_required? == false,
         "needs_licence #{raw.inspect} is NOT licence-required (rent_motorcycle stays shut)")
  assert(v.licence_free? == true,
         "needs_licence #{raw.inspect} IS licence-free (start_rental is the right verb)")
end

# ── 3. AMBIGUOUS: neither door opens ─────────────────────────────────────────
#
# A NULL column, or a value Rails recognises as neither, must answer false to
# BOTH predicates — the property the model comment claims and the reason the
# two gates cannot drift apart.
#
# `""` IS IN THIS LIST AND THAT IS THE CORRECTION THIS SPEC FOUND. The model's
# comment said the empty string reads as licence-FREE, alongside `false` and
# `"0"`. It does not: `ActiveModel::Type::Boolean#cast_value` special-cases `""`
# to nil BEFORE consulting FALSE_VALUES, so an empty `needs_licence` opens
# neither verb. Written as an assertion at the moment it was measured, and the
# model comment corrected to match rather than the other way round.
[nil, ""].each do |raw|
  v = vehicle_reading(raw)
  assert(v.licence_free? == false,     "needs_licence #{raw.inspect} opens no licence-free door")
  assert(v.licence_required? == false, "needs_licence #{raw.inspect} opens no motorcycle door")
end

# ── 4. the real column still behaves (the control) ───────────────────────────
#
# Without this the assertions above could pass over a predicate that had
# stopped tracking the column at all. Uses the declared boolean type, i.e. what
# the shipped schema actually hands the gate.
assert(Scooter.new(needs_licence: true).licence_required?, "a real TRUE column is licence-required")
assert(Scooter.new(needs_licence: false).licence_free?,    "a real FALSE column is licence-free")

# ── 5. both gates still ASK (a predicate nobody calls proves nothing) ────────
{
  "app/operations/start_rental_operation.rb"    => "licence_free?",
  "app/operations/rent_motorcycle_operation.rb" => "licence_required?",
}.each do |rel, predicate|
  path = Rails.root.join(rel)
  assert(File.exist?(path), "#{rel} exists")
  src = File.exist?(path) ? File.read(path) : ""
  # Comment lines dropped: both files DISCUSS the other verb's predicate.
  code = src.each_line.reject { |l| l.strip.start_with?("#") }.join
  assert(code.include?(predicate), "#{rel} still gates on Scooter##{predicate}")
  assert(!code.match?(/\bneeds_licence\b/),
         "#{rel} reads the column only through the predicate, never raw")
end

if FAILURES.empty?
  puts "\nK-724 licence-flag spec: ALL PASS (#{TRUTHY.size} truthy, #{FALSY.size} falsy, 2 ambiguous)"
  exit 0
else
  puts "\nK-724 licence-flag spec: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
