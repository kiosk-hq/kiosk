# frozen_string_literal: true

# WHAT A stylish WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half of this object lives in the gem: {Kiosk::OperationResult} in
# kiosk-server holds the constructor and the ok/refused/status trio, and every
# demo subclasses it. It was hand-copied into all seven demos until K-792 and
# T-089 promoted it — the part that repeated had no per-app decision in it,
# and `:per_demo` in bin/check-demo-copies meant nothing compared the copies.
# What stays here is the part that DOES carry a decision: the STATUSES map.
#
# stylish has no second (human) surface for this verb — its web page is
# read-only counts, and the staff calendar is a wire query gated on an IdP role.
# The seam is still the right shape and not speculation: `book_appointment` is
# THREE input guards whose whole reason for existing is that ActiveRecord's
# timestamp cast fails silently in two directions (K-692), and a guard that
# `render`s cannot be exercised from a console or reused by a second door. It is
# also the one verb in the fleet whose refusal sentence enumerates the valid
# values, which is a business decision about recoverability rather than an HTTP
# concern.
class OperationResult < Kiosk::OperationResult
  # The ONE code stylish's write refuses with, and the Rails status symbol it
  # renders as. Deliberately NOT the full fourteen-code wire vocabulary: a code
  # this app never produces has no business having a mapping here, and `fetch`
  # turning a typo into a loud KeyError is the point of writing it out. tudu's
  # copy lists two, hoteling's/skooti's/getgrocery's four; stylish's is the
  # SHORTEST in the fleet and that is a fact about the demo, not an omission —
  # every service is always bookable (K-446: infinite capacity, overbooking
  # allowed), so there is no `conflict` to answer, and `book_appointment` is
  # scoped to the caller by construction, so there is no `forbidden` either. The
  # only way to be refused here is to pass something the salon cannot read.
  STATUSES = { "bad_request" => :bad_request }.freeze
end
