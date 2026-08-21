# frozen_string_literal: true

# WHAT A skooti WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half of this object lives in the gem: {Kiosk::OperationResult} in
# kiosk-server holds the constructor and the ok/refused/status trio, and every
# demo subclasses it. It was hand-copied into all seven demos until K-792 and
# T-089 promoted it — the part that repeated had no per-app decision in it,
# and `:per_demo` in bin/check-demo-copies meant nothing compared the copies.
# What stays here is the part that DOES carry a decision: the STATUSES map.
#
# skooti has no second (human) surface for these verbs — its web page is
# read-only fleet counts, and POST /kyc/callback is the BROKER's leg, which
# shares no behaviour with any verb (it approves a request no verb can approve,
# and it looks the row up unscoped because the caller is not a principal). The
# seam is still the right shape and not speculation: it is what keeps
# `start_rental`'s four gates and `rent_motorcycle`'s five out of a controller,
# where a `render` in the middle of a transaction is what every earlier slice
# had to reason about — and it is what lets both rental verbs share ONE copy of
# the Ed25519 activation (see {RentalActivation}), which is a physical-lock
# contract that must not be able to drift between two verbs.
class OperationResult < Kiosk::OperationResult
  # The codes skooti's verbs refuse with, and the Rails status symbol each
  # renders as. Deliberately NOT the full fourteen-code wire vocabulary: a code
  # this app never produces has no business having a mapping here, and `fetch`
  # turning a typo into a loud KeyError is the point of writing it out. tudu's
  # copy lists two and hoteling's four; skooti's four are the three its handlers
  # raised as `Errors::` classes before the conversion (bad_request, forbidden,
  # not_found) plus `kyc_required` — which is the reason this table cannot be
  # shared with the siblings even where the count matches. `kyc_required` and
  # `forbidden` are BOTH 403, so the code is not derivable from the status: it
  # is the only thing that tells an assistant "go and get attested" apart from
  # "this is not yours". `quota_exceeded` is the fifth (K-586) — the
  # per-principal cap on outstanding broker intakes, and the one refusal on
  # this origin that means "come back later" rather than "no": 429 is the
  # status §9 gives that code, and it is the only one an assistant can read as
  # temporary without parsing prose.
  STATUSES = {
    "bad_request"    => :bad_request,
    "forbidden"      => :forbidden,
    "not_found"      => :not_found,
    "kyc_required"   => :forbidden,
    "quota_exceeded" => :too_many_requests,
  }.freeze
end
