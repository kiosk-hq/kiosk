# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/request_validation"

module Kiosk
  module Server
    # RESPONSE-shape validation: a verb's rendered payload checked against the
    # `output_schema` that verb DECLARES (T-073 = A, T-068 slice 3).
    #
    # == Why this exists at all
    #
    # 0.4 retires the envelope (T-072 = C): a success body is the handler's
    # payload verbatim, so `output_schema` is the ONLY machine-readable
    # statement of what a call returns — the `kind` discriminator that used to
    # carry it is gone. A descriptor that MIS-states the shape is therefore
    # worse than one that says nothing: the assistant shapes its parse from it,
    # the derived OpenAPI document publishes it, and neither ever meets the
    # handler that disagrees.
    #
    # A declaration nothing executes drifts the day after it is written. This is
    # what executes it: with `Kiosk.configuration.validate_responses` on, EVERY
    # answer a query or action produces is validated against its own declared
    # schema, and a mismatch is a loud `action_failed` (500) naming the verb and
    # the pointer that failed — an operator-side BUG, surfaced where it is
    # cheapest to fix, rather than a lie shipped to assistants.
    #
    # == Where it runs, and why there rather than at the wire
    #
    # {Executor}, on the {Result} — NOT in a controller. Both wires reach the
    # Executor (`POST <endpoint>/{query,run}` until the cutover, and the 0.4
    # per-verb endpoints), and the payload it validates is {Result#to_payload},
    # which is the 0.4 answer shape whichever wire asked for it. So one hook
    # covers both, and it keeps covering the survivor after the cutover deletes
    # the other.
    #
    # == The flag, and what it is FOR
    #
    # `validate_responses` defaults to FALSE. It is a DEVELOPMENT/CI assertion,
    # not a request check: nothing a caller sends can trigger it, and turning it
    # on in production would convert a descriptor typo into a 500 for a caller
    # who did nothing wrong. All seven demos, the e2e fixture origin and the
    # generated app turn it on, which is what makes each demo's own CI task list
    # a per-verb conformance proof rather than a smoke test.
    #
    # `pay` and `schema` are engine verbs with no operator descriptor, so they
    # are not validated here; their shapes are fixed by the spec and asserted
    # directly in this gem's own suite.
    module ResponseValidation
      module_function

      # Validate ONE verb's rendered payload against its declared output_schema.
      #
      # @param payload [Object] the 0.4 answer body ({Result#to_payload})
      # @param output_schema [Hash, nil] the verb's declaration; nil skips
      # @param verb [String] the wire name, for the message
      # @param kind [Symbol] :query or :action, for the message
      # @raise [Errors::ActionFailed] naming the verb and the failing pointers
      # @raise [Errors::ConfigurationError] when json_schemer is not loadable
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

      # The first few failures, as `<pointer>: <message>`, capped so a wholesale
      # shape mismatch cannot produce a message longer than the payload.
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
