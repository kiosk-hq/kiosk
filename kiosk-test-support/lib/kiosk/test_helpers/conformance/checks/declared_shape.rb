# frozen_string_literal: true

module Kiosk
  module TestHelpers
    module Conformance
      module Checks
        # The arguments satisfy the verb's input_schema and its answer satisfies
        # its output_schema; the two failures are reported separately.
        module DeclaredShape
          extend Helpers

          module_function

          def call(origin, name, params:, as:)
            verb = find_verb(origin, name)
            return verb if verb.is_a?(Outcome)

            arguments = arguments_for(verb, params)
            missing_schema(verb) ||
              input_rejected(origin, verb, params, arguments) ||
              answer_checked(origin, verb, params, as)
          end

          def missing_schema(verb)
            return no_input_schema(verb) if verb.input_schema.nil?

            no_output_schema(verb) if verb.output_schema.nil?
          end

          def no_input_schema(verb)
            Conformance.fail(
              :declared_shape, subject: verb.name,
                               message: "#{verb} publishes no input_schema. Both schemas are required of every " \
                                        'verb; declare one (a verb that takes nothing declares the closed empty ' \
                                        'object) rather than leaving callers to guess.'
            )
          end

          def no_output_schema(verb)
            Conformance.fail(
              :declared_shape, subject: verb.name,
                               message: "#{verb} publishes no output_schema, so nothing states the shape of its " \
                                        'answer. Declare one — with no response envelope it is the only ' \
                                        'machine-readable statement a caller has.'
            )
          end

          def input_rejected(origin, verb, params, arguments)
            errors = schema_errors(origin, arguments, verb.input_schema, verb, 'input_schema')
            return if errors.empty?

            Conformance.fail(
              :declared_shape, subject: verb.name,
                               message: "the arguments#{params_provenance(verb, params)} do not satisfy #{verb}'s " \
                                        "own input_schema: #{errors.join('; ')}. Fix whichever is wrong — a " \
                                        'published example an assistant cannot copy is worse than none.',
                               details: { verb: verb.name, stage: :input, errors: errors, params: arguments }
            )
          end

          def answer_checked(origin, verb, params, as)
            executed = Checks.executes(origin, verb.name, params: params, as: as)
            return executed if executed.failed?

            answer = executed.details[:answer]
            errors = schema_errors(origin, answer, verb.output_schema, verb, 'output_schema')
            errors.empty? ? answer_accepted(verb, answer) : answer_rejected(verb, answer, errors)
          end

          def answer_accepted(verb, answer)
            Conformance.pass(
              :declared_shape, subject: verb.name,
                               message: "#{verb} answered a payload its own output_schema accepts",
                               details: { verb: verb.name, answer: answer }
            )
          end

          def answer_rejected(verb, answer, errors)
            Conformance.fail(
              :declared_shape, subject: verb.name,
                               message: "#{verb} rendered a payload its own output_schema rejects: " \
                                        "#{errors.join('; ')}. The descriptor and the handler disagree; fix " \
                                        'whichever is wrong.',
                               details: { verb: verb.name, stage: :output, errors: errors, answer: answer }
            )
          end
        end
      end
    end
  end
end
