# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/request_validation"

module Kiosk
  module Server
    # RESPONSE-shape validation: a verb's rendered payload checked against the
    # `output_schema` that verb DECLARES.
    #
    # == Why this exists at all
    #
    # A success body is the handler's payload verbatim, with no envelope around
    # it, so `output_schema` is the ONLY machine-readable statement of what a
    # call returns. A descriptor that MIS-states the shape is therefore worse
    # than one that says nothing: the assistant shapes its parse from it, the
    # derived OpenAPI document publishes it, and neither ever meets the handler
    # that disagrees.
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
    # {Executor}, on the {Result} — NOT in a controller. Every per-verb
    # endpoint reaches the Executor whatever its kind, and the payload it
    # validates is {Result#to_payload}, the one answer shape they all produce.
    # So a single hook covers the whole wire, and a verb added tomorrow is
    # covered the moment it dispatches.
    #
    # == The flag, and what it is FOR
    #
    # `validate_responses` defaults to FALSE. It is a DEVELOPMENT/CI assertion,
    # not a request check: nothing a caller sends can trigger it, and turning it
    # on in production would convert a descriptor typo into a 500 for a caller
    # who did nothing wrong. The seven demos and the e2e fixture origin turn it
    # on, which is what makes each demo's own CI task list a per-verb
    # conformance proof rather than a smoke test.
    #
    # THE DEMOS SPELL IT `!Rails.env.production?`, NOT `true`. They are
    # DEPLOYED — every one of the env templates sets `RAILS_ENV=production` — so
    # the warning two sentences up is aimed squarely at them: with the flag on,
    # the live demo subdomains an assistant is pointed at would answer a 500 to
    # a caller who did nothing wrong over an operator's descriptor typo.
    # Nothing is lost from the proof, because the task lists that ARE the
    # proof run in development. And it matters that the demo initializer is the
    # artefact `onboarding.html` sends an adopting operator to copy: an example
    # is also an instruction.
    #
    # THE INSTALL GENERATOR WRITES BOTH FLAGS, AS ACTIVE LINES.
    # Its initializer template sets `validate_requests` to `true` and
    # `validate_responses` to `!Rails.env.production?` — the demos' posture,
    # arrived at for the demos' reason — each under a comment giving its own
    # reason, and both beneath a paragraph saying that the UNCONDITIONAL
    # per-verb coerce-then-validate obligation is not either of them. So a
    # freshly generated app does NOT inherit the `false` default above: it
    # starts with the caller-facing shape check on and the operator-facing
    # output check on everywhere except production, and an operator who wants
    # the default opts OUT by editing the line.
    #
    # The two values above are BOUND:
    # `spec/generators/kiosk/install_generator_spec.rb` reads them out of the
    # template and fails unless the sentence above states them, so the next
    # change to what the generator writes reddens the suite instead of quietly
    # falsifying this comment.
    #
    # `pay` and `schema` are engine verbs with no operator descriptor, so they
    # are not validated here; their shapes are fixed by the spec and asserted
    # directly in this gem's own suite.
    module ResponseValidation
      module_function

      # Validate ONE verb's rendered payload against its declared output_schema.
      #
      # @param payload [Object] the answer body ({Result#to_payload})
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
