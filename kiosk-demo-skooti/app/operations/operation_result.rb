# frozen_string_literal: true

# WHAT A skooti WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The tudu/hoteling object, verbatim in shape and for the same reason: an
# Operation is where the write logic lives, and it must be able to REFUSE
# without knowing how a refusal is presented. It renders nothing, redirects
# nothing and knows no HTTP, so the same call works from the wire handler, from
# a rake task, or from a console.
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
#
# A refusal carries the wire's `error.code` STRING rather than an exception
# class, for the reason T-054 settled: the code table is the contract, not a
# hierarchy.
class OperationResult
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
  # "this is not yours".
  STATUSES = {
    "bad_request"  => :bad_request,
    "forbidden"    => :forbidden,
    "not_found"    => :not_found,
    "kyc_required" => :forbidden,
  }.freeze

  attr_reader :value, :code, :message, :hint

  # @param value [Hash] the answer, exactly as it goes on the wire.
  def self.ok(value) = new(value: value)

  def self.refused(code:, message:, hint: nil) = new(code: code, message: message, hint: hint)

  def initialize(value: nil, code: nil, message: nil, hint: nil)
    @value   = value
    @code    = code
    @message = message
    @hint    = hint
    freeze
  end

  def ok? = @code.nil?

  # The Rails status symbol this refusal renders as. Raises on a code with no
  # mapping rather than guessing one — the same refusal-to-guess the wire's own
  # `Errors::STATUS_CODES` makes for 402 and 500.
  def status = STATUSES.fetch(@code)
end
