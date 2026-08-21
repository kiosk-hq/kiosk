# frozen_string_literal: true

module Kiosk
  # WHAT A WRITE OPERATION ANSWERS — one value, or one refusal.
  #
  # An Operation is where a write's logic lives, and it must be able to REFUSE
  # without knowing how a refusal is PRESENTED. This is the seam that lets one
  # implementation of a write serve both surfaces an operator may have: the
  # Kiosk wire renders `render json:, status:`, a human web controller
  # redirects with a flash. An OperationResult renders nothing, redirects
  # nothing and knows no HTTP, so the same call works from a {Kiosk::Handler}
  # handler, from a rake task, or from a console.
  #
  #   class PlaceOrder
  #     def call(...)
  #       return Result.refused(code: "forbidden", message: "not your cart") unless mine?
  #
  #       Result.ok({ "order_id" => order.id })
  #     end
  #   end
  #
  # A refusal carries the wire's `error.code` STRING rather than an exception
  # class: the code table is the contract, not a hierarchy. Both surfaces
  # branch on that string — a handler maps it to an HTTP status, a web
  # controller decides between a flash and a re-raise — and neither can be
  # surprised by a class it has never heard of.
  #
  # == The one thing you must supply: STATUSES
  #
  # Subclass this and declare the `error.code` → Rails status symbol map for
  # the refusals YOUR app actually makes:
  #
  #   class OperationResult < Kiosk::OperationResult
  #     STATUSES = {
  #       "bad_request" => :bad_request,
  #       "forbidden"   => :forbidden,
  #     }.freeze
  #   end
  #
  # The map is deliberately NOT shipped here, and that is the whole design.
  # A code your app never produces has no business having a mapping, so the
  # table is not derivable from the protocol's fourteen codes; and it is not
  # derivable from the status either, because the wire vocabulary is not
  # injective — `kyc_required` and `forbidden` are BOTH 403, and only the
  # operator knows which one a given refusal means. {#status} therefore raises
  # on an unmapped code rather than guessing one, the same refusal-to-guess
  # {Kiosk::Server::Errors::STATUS_CODES} makes.
  #
  # == Why this ships in kiosk-server
  #
  # It is a frozen plain value object: four attributes, no ActiveRecord, no
  # database, no reach into the host application's models — so it does not
  # engage the constraint that keeps Kiosk neutral toward the host's schema.
  # It belongs next to {Kiosk::Handler}, the operator-facing
  # mixins whose handlers are the things that return it, in the one gem every
  # origin already installs (K-792, T-089).
  class OperationResult
    # Empty on purpose — the base class refuses NOTHING, because it does not
    # know your app. A subclass that forgets to declare its own inherits this
    # and {#status} raises a KeyError naming the code it could not map.
    STATUSES = {}.freeze

    # @return [Object, nil] the answer, on success. String-keyed by convention
    #   when it goes on the wire: a handler renders the hash straight to JSON,
    #   and a second (human) surface reads the same object, so one shape has to
    #   serve both readers.
    attr_reader :value

    # @return [String, nil] the wire `error.code`, on a refusal. nil on success.
    attr_reader :code

    # @return [String, nil] the human sentence the refusal carries.
    attr_reader :message

    # @return [String, nil] optional: what the caller could do instead.
    attr_reader :hint

    # @param value [Object] the answer.
    # @return [OperationResult] a success.
    def self.ok(value) = new(value: value)

    # @param code [String] one of the wire's `error.code` values, and one your
    #   subclass's STATUSES maps.
    # @param message [String] the sentence the caller sees.
    # @param hint [String, nil] dropped from the envelope when nil.
    # @return [OperationResult] a refusal.
    def self.refused(code:, message:, hint: nil) = new(code: code, message: message, hint: hint)

    def initialize(value: nil, code: nil, message: nil, hint: nil)
      @value   = value
      @code    = code
      @message = message
      @hint    = hint
      freeze
    end

    # @return [Boolean] true when this is an answer rather than a refusal.
    def ok? = @code.nil?

    # The Rails status symbol this refusal renders as.
    #
    # @raise [KeyError] when the subclass's STATUSES has no entry for the code
    #   — a loud failure at the one place that could have guessed.
    # @return [Symbol]
    def status
      self.class::STATUSES.fetch(@code) do
        raise KeyError, "#{self.class}::STATUSES has no mapping for #{@code.inspect} — " \
                        "add it there, or stop refusing with that code"
      end
    end
  end
end
