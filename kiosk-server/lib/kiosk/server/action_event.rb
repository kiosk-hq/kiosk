# frozen_string_literal: true

module Kiosk
  module Server
    # ONE ACTION INVOCATION, AS THE OPERATOR'S AUDIT SINK RECEIVES IT.
    #
    # This is the whole payload of the audit seam: {Executor} builds one of
    # these per `run` invocation — success and failure alike — and hands it to
    # `Kiosk.configuration.audit_sink`. With no sink configured NOTHING is
    # built and nothing is emitted; Kiosk itself stores none of this.
    #
    # ── WHY THIS IS A VALUE OBJECT AND NOT A TABLE ────────────────────────
    #
    # Kiosk offers the CAPABILITY and keeps none of the data: no table, no
    # retention, no purge task it would then owe you, and no undiscussed
    # decision about somebody else's PII — an operator who wants a durable
    # trail writes it in their own sink, under their own policy.
    #
    # ── ARGUMENTS ARRIVE IN FULL. THAT IS THE POINT. ─────────────────────
    #
    # {#args} is exactly what the handler received — the delivery address, the
    # passenger name, the cart, the booking reference. Kiosk does NOT redact
    # them on your behalf, because a redaction Kiosk chose would be a
    # retention policy Kiosk invented for your data. What you do with them is
    # yours, and so is the responsibility: **if you write this event anywhere,
    # you are the data controller for whatever the arguments contain.**
    #
    # Redaction is therefore one call away rather than absent — see
    # {#with_arg_types} (names and JSON types, no values), {#without_args},
    # and {#arg_types} if you want to build your own shape:
    #
    #   Kiosk.configure do |c|
    #     # everything, values included — your call, your responsibility
    #     c.audit_sink = ->(e) { AuditRow.create!(**e.to_h) }
    #
    #     # or: what was called and by whom, never what was passed
    #     c.audit_sink = ->(e) { Rails.logger.info(e.with_arg_types.to_h.to_json) }
    #
    #     # or: per-field, because only you know which of your fields are hot
    #     c.audit_sink = ->(e) { Siem.record(e.to_h.merge(args: e.args.except(:card_token))) }
    #   end
    #
    # ── WHAT IS NOT IN HERE ──────────────────────────────────────────────
    #
    # The upstream IdP's `claims` hash is deliberately absent: it belongs to
    # the token, not to the invocation, and an operator who wants it already
    # has it in their own IdP adapter. The four identity facts that DO travel
    # ({#user_id}, {#agent_id}, {#role}, {#actor}) are the ones an audit trail
    # is about — who asked, as what, through which channel.
    #
    # @!attribute [r] action
    #   The action's wire name (`"book_appointment"`), always a registered one.
    # @!attribute [r] user_id
    #   The principal, in the provider's own user-id type.
    # @!attribute [r] agent_id
    #   The acting assistant's credential id, or nil when `actor != "agent"`.
    # @!attribute [r] role
    #   The active role for this token, or nil for a role-less principal.
    # @!attribute [r] actor
    #   `"agent"` | `"human"` | `"service"`.
    # @!attribute [r] args
    #   The arguments AS THE HANDLER RECEIVED THEM — symbol keys, values
    #   verbatim, nothing removed.
    # @!attribute [r] status
    #   {OK} or {ERROR}.
    # @!attribute [r] error_class
    #   The raised exception's class name on the {ERROR} branch, else nil.
    # @!attribute [r] error_message
    #   The raised exception's message, UNTRUNCATED, else nil.
    # @!attribute [r] cause_class
    #   The class name of what the error above WRAPS, when it wraps anything —
    #   see the note below. nil on the {OK} branch and on a raise with no cause.
    # @!attribute [r] cause_message
    #   That exception's message, UNTRUNCATED, else nil.
    # @!attribute [r] invoked_at
    #   When the invocation STARTED — not when the sink was called.
    #
    # ── THE CAUSE, BECAUSE THE ERROR IS OFTEN A WRAPPER ──────────────────
    #
    # {Executor} emits whatever reached its audit seam, and on the failure
    # branch that is usually a Kiosk wrapper rather than the handler's own
    # exception: an unhandled raise becomes `Errors::ActionFailed` reading
    # `Action "place_order" raised RuntimeError`, because the handler's own
    # sentence is not the wire's to publish. That is right FOR THE
    # WIRE and wrong here — a sink is operator-side, in the operator's own
    # process, already receiving the arguments in full, and it is what an
    # operator builds alerting on.
    #
    # Ruby sets `Exception#cause` to whatever was being handled when the
    # wrapper was raised, so the handler's own error is already attached and
    # nothing has to be threaded through the Executor to get it here. It is
    # carried as its OWN pair rather than replacing {#error_class}: the two
    # answer different questions — what the wire refused with, and what
    # actually went wrong — and a sink that alerts on `error_class` today keeps
    # meaning what it meant. Only the IMMEDIATE cause travels; a deeper chain
    # is still reachable through the exception the operator's own logger got.
    #
    # Declared as a CLASS over `Data.define` rather than as `Name = Data.define
    # do … end`: a constant assigned inside that block belongs to the LEXICAL
    # scope ({Kiosk::Server}), not to the value class, so `ActionEvent::OK`
    # would not resolve.
    class ActionEvent < Data.define(:action, :user_id, :agent_id, :role, :actor, :args,
                                    :status, :error_class, :error_message,
                                    :cause_class, :cause_message, :invoked_at)
      OK    = "ok"
      ERROR = "error"

      # Builds the event from the pieces {Executor} has at the seam.
      #
      # @param identity [Kiosk::Identity]
      # @param name [String, Symbol] the action's wire name
      # @param args [Hash] as the handler received them
      # @param status [String] {OK} or {ERROR}
      # @param error [Exception, nil]
      # @param invoked_at [Time]
      def self.build(identity:, name:, args:, status:, error: nil, invoked_at: Time.now)
        cause = cause_of(error)
        new(
          action:        name.to_s,
          user_id:       identity.user_id,
          agent_id:      identity.agent_id,
          role:          identity.role,
          actor:         identity.actor,
          args:          args.is_a?(Hash) ? args : {},
          status:        status.to_s,
          error_class:   error && error.class.name,
          error_message: error && error.message.to_s,
          cause_class:   cause && cause.class.name,
          cause_message: cause && cause.message.to_s,
          invoked_at:    invoked_at,
        )
      end

      # The exception `error` wraps, or nil. Guarded rather than read straight
      # off `#cause`: an exception re-raised inside its own `rescue` is its own
      # cause in some Ruby versions, and reporting a wrapper as the thing it
      # wraps would be worse than reporting nothing.
      #
      # @param error [Exception, nil]
      # @return [Exception, nil]
      def self.cause_of(error)
        return nil unless error.is_a?(::Exception)

        cause = error.cause
        cause.is_a?(::Exception) && !cause.equal?(error) ? cause : nil
      end

      def ok?    = status == OK
      def error? = status == ERROR

      # Each argument's NAME with its JSON TYPE in place of its value —
      # `{"salon_id" => "integer", "slot" => "string"}`. Says what shape the
      # verb was called with and discloses nothing. The vocabulary is JSON
      # Schema's own, so the recorded shape reads in the same words the verb's
      # `input_schema` declares it in.
      #
      # @return [Hash{String=>String}]
      def arg_types
        args.to_h { |key, value| [key.to_s, self.class.json_type(value)] }
      end

      # This event with {#args} replaced by {#arg_types} — the one-call
      # redaction. Was the DEFAULT while the log was a table; it is now an
      # offer, because the choice is the operator's.
      # @return [ActionEvent]
      def with_arg_types = with(args: arg_types)

      # This event with the arguments dropped entirely.
      # @return [ActionEvent]
      def without_args = with(args: {})

      def self.json_type(value)
        case value
        when nil            then "null"
        when true, false    then "boolean"
        when Integer        then "integer"
        when Float, Numeric then "number"
        when Array          then "array"
        when Hash           then "object"
        else "string"
        end
      end
    end
  end
end
