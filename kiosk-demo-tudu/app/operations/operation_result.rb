# frozen_string_literal: true

# WHAT A tudu WRITE OPERATION ANSWERS — one value, or one refusal.
#
# tudu is the only demo whose HUMAN web UI drives the same writes the agent wire
# drives, and the two surfaces present an answer completely differently: the
# wire renders `render json:, status:`, the web UI redirects with a flash. This
# object is the seam that lets ONE implementation of a write serve both without
# either surface's vocabulary leaking into it — an operation renders nothing,
# redirects nothing and knows no HTTP.
#
# A refusal carries the wire's `error.code` STRING rather than an exception
# class, for the reason T-054 settled: the code table is the contract, not a
# hierarchy. Both surfaces branch on that string — the handler controller maps
# it to a status, the web controller decides between a flash and a re-raise —
# and neither can be surprised by a class it has never heard of.
class OperationResult
  # The two codes tudu's writes refuse with, and the Rails status symbol each
  # renders as. Deliberately NOT the full fourteen-code wire vocabulary: a code
  # this app never produces has no business having a mapping here, and `fetch`
  # turning a typo into a loud KeyError is the point of writing it out.
  STATUSES = { "bad_request" => :bad_request, "forbidden" => :forbidden }.freeze

  attr_reader :value, :code, :message, :hint

  # @param value [Hash] the answer, STRING-keyed exactly as it goes on the wire.
  #   String keys are not cosmetic: the handler renders this hash straight to
  #   JSON and the web controller reads `value["list_id"]` out of the same
  #   object, so one shape has to serve both readers.
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
