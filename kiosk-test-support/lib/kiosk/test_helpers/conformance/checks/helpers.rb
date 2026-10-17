# frozen_string_literal: true

require 'json'
require 'json_schemer'

module Kiosk
  module TestHelpers
    module Conformance
      module Checks
        # `params:` default: the verb's own `example_params`, else `{}`.
        EXAMPLE = :__kiosk_example_params__

        # Refusing the second principal outright scopes as well as narrowing does;
        # a 400 or 500 stays a failure.
        SCOPING_REFUSALS = [403, 404].freeze

        # Functions the four checks share.
        module Helpers
          module_function

          # The verb by name, or a failing Outcome listing the declared ones.
          def find_verb(origin, name)
            wanted = name.to_s
            found  = origin.verbs.find { |verb| verb.name == wanted }
            return found if found

            known = origin.verbs.map(&:name).sort
            Conformance.fail(
              :unknown_verb, subject: wanted,
                             message: "no verb named #{wanted.inspect} is declared by this origin. " \
                                      "Declared: #{known.empty? ? '(none at all)' : known.join(', ')}.",
                             details: { asked: wanted, known: known }
            )
          end

          # «403 forbidden», or nil when the outcome is not a scoping refusal.
          def refusal_status(outcome)
            return nil unless outcome.failed?

            status = outcome.details[:error_status]
            return nil unless SCOPING_REFUSALS.include?(status)

            [status, outcome.details[:error_code]].compact.join(' ')
          end

          def principal_label(subject)
            subject.respond_to?(:id) ? "#{subject.class}(#{subject.id})" : subject.inspect
          end

          def arguments_for(verb, params)
            return normalize(params) unless params.equal?(EXAMPLE)

            normalize(verb.example_params || {})
          end

          def params_provenance(verb, params)
            return '' unless params.equal?(EXAMPLE)

            verb.example_params.nil? ? ' (no arguments)' : ' with its own example_params'
          end

          # Some routers raise for "no route", others return nil.
          def recognize(origin, path, http_method)
            origin.recognize(path, method: http_method)
          rescue StandardError
            nil
          end

          # Schema failures as strings; an origin that validates for itself answers them.
          def schema_errors(origin, payload, schema, verb, slot)
            if origin.respond_to?(:schema_errors)
              return Array(origin.schema_errors(payload, schema: schema, verb: verb.name,
                                                         kind: verb.kind, slot: slot))
            end

            JSONSchemer.schema(normalize(schema)).validate(normalize(payload)).map do |error|
              pointer = error['data_pointer'].to_s
              "#{pointer.empty? ? '(root)' : pointer}: #{error['error']}"
            end
          end

          # The value as a caller receives it, after the JSON round trip.
          def normalize(value)
            JSON.parse(JSON.generate([value])).first
          end

          # An action's single object counts as one row.
          def rows_of(answer)
            normalized = normalize(answer)
            normalized.is_a?(Array) ? normalized : [normalized].compact
          end

          def summarise_answer(answer)
            case answer
            when Array then "#{answer.length} row(s)"
            when Hash  then "an object with keys #{answer.keys.map(&:to_s).sort.inspect}"
            when nil   then 'nothing'
            else answer.class.name
            end
          end

          def describe_error(error)
            parts = ["#{error.class.name}: #{error.message}"]
            parts << "code=#{error.code}" if error.respond_to?(:code) && error.code
            parts << "hint: #{error.hint}" if error.respond_to?(:hint) && error.hint
            parts.join(', ')
          end
        end
      end
    end
  end
end
