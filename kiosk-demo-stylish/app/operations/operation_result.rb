# frozen_string_literal: true

# WHAT A stylish WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The tudu/hoteling/skooti/getgrocery/philslist object, verbatim in shape and for
# the same reason: an Operation is where the write logic lives, and it must be
# able to REFUSE without knowing how a refusal is presented. It renders nothing,
# redirects nothing and knows no HTTP, so the same call works from the wire
# handler, from a rake task, or from a console.
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
#
# A refusal carries the wire's `error.code` STRING rather than an exception
# class, for the reason T-054 settled: the code table is the contract, not a
# hierarchy.
class OperationResult
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
