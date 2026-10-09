# frozen_string_literal: true

module Kiosk
  module Server
    # One action invocation, as `Kiosk.configuration.audit_sink` receives it.
    # {#args} arrive unredacted: whoever stores this event controls that data.
    # {#cause_class}/{#cause_message} carry the handler's own error under a Kiosk wrapper.
    class ActionEvent < Data.define(:action, :user_id, :agent_id, :role, :actor, :args,
                                    :status, :error_class, :error_message,
                                    :cause_class, :cause_message, :invoked_at)
      OK    = "ok"
      ERROR = "error"

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

      # An exception re-raised inside its own `rescue` can be its own cause.
      def self.cause_of(error)
        return nil unless error.is_a?(::Exception)

        cause = error.cause
        cause.is_a?(::Exception) && !cause.equal?(error) ? cause : nil
      end

      def ok?    = status == OK
      def error? = status == ERROR

      # `{"salon_id" => "integer", "slot" => "string"}`, in JSON Schema type names.
      def arg_types
        args.to_h { |key, value| [key.to_s, self.class.json_type(value)] }
      end

      def with_arg_types = with(args: arg_types)

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
