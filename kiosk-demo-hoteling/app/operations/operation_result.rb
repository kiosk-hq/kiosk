# frozen_string_literal: true

# WHAT A hoteling WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The tudu object, verbatim in shape and for the same reason: an Operation is
# where the write logic lives, and it must be able to REFUSE without knowing how
# a refusal is presented. It renders nothing, redirects nothing and knows no
# HTTP, so the same call works from the wire handler, from a rake task, or from
# a console.
#
# hoteling has no second (human) surface today — its web page is read-only
# counts — so unlike tudu there is no web controller sharing these Operations.
# The seam is still the right shape and not speculation: it is what keeps
# `reserve_room`'s three-part inventory guard and `confirm_booking`'s two gates
# out of a controller, where a `render` in the middle of a transaction is what
# every one of the earlier slices had to reason about.
#
# A refusal carries the wire's `error.code` STRING rather than an exception
# class, for the reason T-054 settled: the code table is the contract, not a
# hierarchy.
class OperationResult
  # The codes hoteling's verbs refuse with, and the Rails status symbol each
  # renders as. Deliberately NOT the full fourteen-code wire vocabulary: a code
  # this app never produces has no business having a mapping here, and `fetch`
  # turning a typo into a loud KeyError is the point of writing it out. tudu's
  # copy lists two; hoteling's four are the four its handlers actually raised
  # before the conversion (bad_request, forbidden, conflict) plus the not_found
  # `hotel_detail` answers for an unknown property.
  STATUSES = {
    "bad_request" => :bad_request,
    "forbidden"   => :forbidden,
    "not_found"   => :not_found,
    "conflict"    => :conflict,
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
