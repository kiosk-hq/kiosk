# frozen_string_literal: true

module Kiosk
  module TestHelpers
    module Conformance
      module Checks
        # Called with these arguments as this principal, the verb answers rather than refusing.
        module Executes
          extend Helpers

          module_function

          def call(origin, name, params:, as:)
            verb = find_verb(origin, name)
            return verb if verb.is_a?(Outcome)

            run(origin, verb, params, arguments_for(verb, params), as)
          end

          def run(origin, verb, params, arguments, as)
            begin
              answer = origin.call(verb.name, kind: verb.kind, params: arguments, as: as)
            rescue StandardError => e
              return refused(verb, params, arguments, e)
            end

            answered(verb, params, arguments, answer)
          end

          def refused(verb, params, arguments, error)
            Conformance.fail(
              :executes, subject: verb.name,
                         message: "#{verb} did not execute: #{describe_error(error)}. " \
                                  "Arguments were #{arguments.inspect}#{params_provenance(verb, params)}.",
                         details: error_details(verb, arguments, error)
            )
          end

          def error_details(verb, arguments, error)
            { verb: verb.name, kind: verb.kind, error: error.class.name, params: arguments,
              error_code: (error.code if error.respond_to?(:code)),
              error_status: (error.http_status if error.respond_to?(:http_status)) }
          end

          def answered(verb, params, arguments, answer)
            Conformance.pass(
              :executes, subject: verb.name,
                         message: "#{verb} executed#{params_provenance(verb, params)} and answered " \
                                  "#{summarise_answer(answer)}",
                         details: { verb: verb.name, kind: verb.kind, params: arguments, answer: answer }
            )
          end
        end
      end
    end
  end
end
