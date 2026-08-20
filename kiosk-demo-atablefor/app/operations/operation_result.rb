# frozen_string_literal: true

# WHAT AN atablefor WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half of this object lives in the gem: {Kiosk::OperationResult} in
# kiosk-server holds the constructor and the ok/refused/status trio, and every
# demo subclasses it. It was hand-copied into all seven demos until K-792 and
# T-089 promoted it — the part that repeated had no per-app decision in it,
# and `:per_demo` in bin/check-demo-copies meant nothing compared the copies.
# What stays here is the part that DOES carry a decision: the STATUSES map.
#
# atablefor has no second (human) surface for these verbs — its reservations
# board is a public read-only window. The seam is still the right shape and not
# speculation: `book_table` ends in a transaction whose double-booking guard is
# in TWO halves (a pre-check and a unique partial index caught in a `rescue`),
# and a `render` in the middle of that is what every T-057 slice had to reason
# about — one of those halves is reached only from inside a `rescue` around an
# INSERT, which is precisely the place a controller has no business being.
class OperationResult < Kiosk::OperationResult
  # The three codes atablefor's writes refuse with, and the Rails status symbol
  # each renders as. Deliberately NOT the full fourteen-code wire vocabulary: a
  # code this app never produces has no business having a mapping here, and
  # `fetch` turning a typo into a loud KeyError is the point of writing it out.
  # These three are exactly the three private renderers this conversion replaced
  # — `bad_request`, the `conflict` BOTH halves of the double-booking guard
  # answer with, and the `forbidden` an owner-scoped cancel earns when it touches
  # no row. There is no `not_found` and there must not be: "no such booking",
  # "not yours" and "already cancelled" are ONE answer, so probing cannot
  # enumerate other principals' booking ids.
  STATUSES = {
    "bad_request" => :bad_request,
    "conflict"    => :conflict,
    "forbidden"   => :forbidden,
  }.freeze
end
