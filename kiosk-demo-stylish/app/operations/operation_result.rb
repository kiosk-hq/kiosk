# frozen_string_literal: true

# WHAT A stylish WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half lives in the gem ({Kiosk::OperationResult}: the constructor and
# the ok/refused/status trio); what stays here carries a per-app decision.
#
# stylish has no second (human) surface for this verb — its web page is
# read-only counts, and the staff calendar is a wire query gated on an IdP role.
# The seam is still the right shape: `book_appointment` is THREE input guards
# (K-692), and a guard that `render`s cannot be exercised from a console or
# reused by a second door.
class OperationResult < Kiosk::OperationResult
  # The ONE code stylish's write refuses with, and the Rails status symbol it
  # renders as. Deliberately NOT the full wire vocabulary — `fetch` turns a typo
  # into a loud KeyError. One entry is a fact about the demo: every service is
  # always bookable (K-446), so there is no `conflict`, and `book_appointment` is
  # caller-scoped by construction, so there is no `forbidden`.
  STATUSES = { "bad_request" => :bad_request }.freeze
end
