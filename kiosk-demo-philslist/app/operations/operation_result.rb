# frozen_string_literal: true

# WHAT A philslist WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The tudu/hoteling/skooti/getgrocery object, verbatim in shape and for the same
# reason: an Operation is where the write logic lives, and it must be able to
# REFUSE without knowing how a refusal is presented. It renders nothing,
# redirects nothing and knows no HTTP, so the same call works from the wire
# handler, from a rake task, or from a console.
#
# philslist has no second (human) surface for these verbs — its public board is
# read-only, and the owner-scoped EDIT authority is deliberately wire-only. The
# seam is still the right shape and not speculation: `post_listing`'s three
# guards and the two owner-scoped UPDATEs are business decisions, and a `render`
# in the middle of them is the thing every T-057 slice had to reason about. It is
# also what lets `edit_listing` and `close_listing` share ONE copy of the shape
# guard and the ownership sentence (see {ListingAccess}) — two copies of an
# access refusal is two chances for one of them to drift.
#
# A refusal carries the wire's `error.code` STRING rather than an exception
# class, for the reason T-054 settled: the code table is the contract, not a
# hierarchy.
class OperationResult
  # The two codes philslist's writes refuse with, and the Rails status symbol
  # each renders as. Deliberately NOT the full fourteen-code wire vocabulary: a
  # code this app never produces has no business having a mapping here, and
  # `fetch` turning a typo into a loud KeyError is the point of writing it out.
  # philslist's two are the two its handlers rendered before the conversion —
  # `bad_request` (an unknown category_slug, a missing title/body, a malformed
  # listing_id) and `forbidden` (an owner-scoped UPDATE that touched no row).
  # There is no `not_found` and there must not be: a listing that does not exist
  # and one that belongs to somebody else answer the SAME 403, so cross-owner
  # probing cannot enumerate which ids exist.
  STATUSES = { "bad_request" => :bad_request, "forbidden" => :forbidden }.freeze

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
