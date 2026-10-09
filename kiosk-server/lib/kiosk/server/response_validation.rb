# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/request_validation"

module Kiosk
  module Server
    # With `c.validate_responses`, checks every verb's answer against its own
    # `output_schema` and fails loudly on a mismatch. Off by default: in
    # production a descriptor typo would become a 500 for an innocent caller.
    module ResponseValidation
      module_function

      def validate_payload!(payload, output_schema:, verb:, kind:)
        return if output_schema.nil?

        RequestValidation.require_schemer!
        schemer = JSONSchemer.schema(RequestValidation.normalize(output_schema))
        errors  = schemer.validate(RequestValidation.normalize(payload)).to_a
        return if errors.empty?

        raise Errors::ActionFailed.new(
          "#{kind} #{verb.inspect} rendered a payload its own output_schema rejects: " \
          "#{summarise(errors)}",
          hint: "the descriptor and the handler disagree — `#{verb}` publishes an " \
                "output_schema that its rendered answer does not satisfy. Fix whichever " \
                "is wrong; a published schema an assistant cannot rely on is worse than " \
                "none. (Kiosk.configuration.validate_responses is on.)",
        )
      end

      MAX_REPORTED = 5

      def summarise(errors)
        reported = errors.first(MAX_REPORTED).map do |error|
          pointer = error["data_pointer"].to_s
          "#{pointer.empty? ? "(root)" : pointer}: #{error["error"]}"
        end
        reported << "(#{errors.length - MAX_REPORTED} more)" if errors.length > MAX_REPORTED
        reported.join("; ")
      end
    end
  end
end
