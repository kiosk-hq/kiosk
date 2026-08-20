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
    # ── WHY THIS IS A VALUE OBJECT AND NOT A TABLE (K-828, 2026-08-20) ────
    #
    # It used to be a table. `kiosk.action_log` was a canonical migration
    # every adopter installed, and `Kiosk::Server::ActionLog` — both since
    # deleted — wrote a row per invocation.
    # Phil reversed that on 2026-08-20: «Хранить в БД в рамках kiosk reference
    # impl/demo не будем. Дадим интерфейс для возможности их куда-то выливать
    # по желанию оператора, и на его ответственность по PII.» So Kiosk offers
    # the CAPABILITY and keeps none of the data: no table, no retention, no
    # purge task it would then owe you, and no undiscussed decision about
    # somebody else's PII.
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
    #   The raised exception's message, UNTRUNCATED (the old 500-char cap was
    #   a `text` column's problem, not yours), else nil.
    # @!attribute [r] invoked_at
    #   When the invocation STARTED — not when the sink was called.
    #
    # Declared as a CLASS over `Data.define` rather than as `Name = Data.define
    # do … end`: a constant assigned inside that block belongs to the LEXICAL
    # scope ({Kiosk::Server}), not to the value class, so `ActionEvent::OK`
    # would not resolve.
    class ActionEvent < Data.define(:action, :user_id, :agent_id, :role, :actor, :args,
                                    :status, :error_class, :error_message, :invoked_at)
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
          invoked_at:    invoked_at,
        )
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
