# frozen_string_literal: true

require "json"
require "json_schemer"

require "kiosk/test_helpers/conformance/outcome"
require "kiosk/test_helpers/conformance/verb"

module Kiosk
  module TestHelpers
    module Conformance
      # The four conformance checks, as pure functions of an origin returning an
      # {Outcome}; the Minitest and RSpec adapters render its message verbatim.
      module Checks
        # `params:` default: the verb's own `example_params`, else `{}`.
        EXAMPLE = :__kiosk_example_params__

        module_function

        # Every declared verb is routed to the verb wire under its own name, GET
        # for a query and POST for an action. No verbs at all fails.
        def routes(origin)
          verbs = origin.verbs
          if verbs.empty?
            return Conformance.fail(
              :routes,
              message: "this origin declares no verbs at all, so there is nothing to route. " \
                       "Either app/controllers/kiosk holds no handler controller, " \
                       "or the registry was read before the engine populated it — build the " \
                       "origin inside the example, not at file load.",
            )
          end

          mount    = origin.mount_path.to_s.chomp("/")
          problems = verbs.flat_map { |verb| route_problems(origin, verb, mount) }

          if problems.empty?
            Conformance.pass(
              :routes,
              message: "all #{verbs.length} declared verbs are routed under #{mount}/ " \
                       "with the method their kind requires",
              details: { verbs: verbs.map(&:name), mount_path: mount },
            )
          else
            Conformance.fail(
              :routes,
              message: "#{problems.length} of this origin's #{verbs.length} declared verbs are " \
                       "not routed as their kind requires:\n  - #{problems.join("\n  - ")}",
              details: { problems: problems, verbs: verbs.map(&:name), mount_path: mount },
            )
          end
        end

        # Called with these arguments as this principal, the verb answers rather than refusing.
        def executes(origin, name, params: EXAMPLE, as: nil)
          verb = find_verb(origin, name)
          return verb if verb.is_a?(Outcome)

          arguments = arguments_for(verb, params)
          begin
            answer = origin.call(verb.name, kind: verb.kind, params: arguments, as: as)
          rescue StandardError => e
            return Conformance.fail(
              :executes, subject: verb.name,
              message: "#{verb} did not execute: #{describe_error(e)}. " \
                       "Arguments were #{arguments.inspect}#{params_provenance(verb, params)}.",
              details: { verb: verb.name, kind: verb.kind, error: e.class.name, params: arguments,
                         error_code: (e.code if e.respond_to?(:code)),
                         error_status: (e.http_status if e.respond_to?(:http_status)) },
            )
          end

          Conformance.pass(
            :executes, subject: verb.name,
            message: "#{verb} executed#{params_provenance(verb, params)} and answered " \
                     "#{summarise_answer(answer)}",
            details: { verb: verb.name, kind: verb.kind, params: arguments, answer: answer },
          )
        end

        # The arguments satisfy the verb's input_schema and its answer satisfies
        # its output_schema; the two failures are reported separately.
        def declared_shape(origin, name, params: EXAMPLE, as: nil)
          verb = find_verb(origin, name)
          return verb if verb.is_a?(Outcome)

          arguments = arguments_for(verb, params)

          if verb.input_schema.nil?
            return Conformance.fail(
              :declared_shape, subject: verb.name,
              message: "#{verb} publishes no input_schema. Both schemas are required of every " \
                       "verb; declare one (a verb that takes nothing declares the closed empty " \
                       "object) rather than leaving callers to guess.",
            )
          end
          if verb.output_schema.nil?
            return Conformance.fail(
              :declared_shape, subject: verb.name,
              message: "#{verb} publishes no output_schema, so nothing states the shape of its " \
                       "answer. Declare one — with no response envelope it is the only " \
                       "machine-readable statement a caller has.",
            )
          end

          input_errors = schema_errors(origin, arguments, verb.input_schema, verb, "input_schema")
          unless input_errors.empty?
            return Conformance.fail(
              :declared_shape, subject: verb.name,
              message: "the arguments#{params_provenance(verb, params)} do not satisfy #{verb}'s " \
                       "own input_schema: #{input_errors.join("; ")}. Fix whichever is wrong — a " \
                       "published example an assistant cannot copy is worse than none.",
              details: { verb: verb.name, stage: :input, errors: input_errors, params: arguments },
            )
          end

          executed = executes(origin, verb.name, params: params, as: as)
          return executed if executed.failed?

          answer = executed.details[:answer]
          errors = schema_errors(origin, answer, verb.output_schema, verb, "output_schema")
          if errors.empty?
            Conformance.pass(
              :declared_shape, subject: verb.name,
              message: "#{verb} answered a payload its own output_schema accepts",
              details: { verb: verb.name, answer: answer },
            )
          else
            Conformance.fail(
              :declared_shape, subject: verb.name,
              message: "#{verb} rendered a payload its own output_schema rejects: " \
                       "#{errors.join("; ")}. The descriptor and the handler disagree; fix " \
                       "whichever is wrong.",
              details: { verb: verb.name, stage: :output, errors: errors, answer: answer },
            )
          end
        end

        # No row `as:` sees reaches `and_not:`, compared whole-row. An empty first
        # answer fails (no positive control), and so does a `published` verb.
        def principal_scope(origin, name, as:, and_not:, params: EXAMPLE)
          verb = find_verb(origin, name)
          return verb if verb.is_a?(Outcome)

          if verb.reach == "published"
            return Conformance.fail(
              :principal_scope, subject: verb.name,
              message: "#{verb} declares `reach: :published`, which says every authenticated " \
                       "caller sees the same rows. Asserting that two principals see different " \
                       "rows asserts the opposite of the descriptor — assert the descriptor, or " \
                       "narrow the reach.",
              details: { verb: verb.name, reach: verb.reach },
            )
          end

          arguments = arguments_for(verb, params)
          mine      = executes(origin, verb.name, params: arguments, as: as)
          return mine if mine.failed?

          theirs  = executes(origin, verb.name, params: arguments, as: and_not)
          refused = refusal_status(theirs)
          return theirs if theirs.failed? && refused.nil?

          own   = rows_of(mine.details[:answer])
          other = refused ? [] : rows_of(theirs.details[:answer])

          if own.empty?
            return Conformance.fail(
              :principal_scope, subject: verb.name,
              message: "#{verb} answered #{principal_label(as)} with nothing, so there is nothing for " \
                       "#{principal_label(and_not)} to be scoped out of. Seed a row that belongs to the " \
                       "first principal — a scoping assertion with no positive control passes " \
                       "on a verb that answers everybody with nothing.",
              details: { verb: verb.name, reach: verb.reach, own: own, other: other },
            )
          end

          leaked = own & other
          if leaked.empty?
            Conformance.pass(
              :principal_scope, subject: verb.name,
              message: refused ?
                         "#{verb} answered #{principal_label(as)} with #{own.length} row(s) and REFUSED " \
                         "#{principal_label(and_not)} outright (#{refused}), which is the strongest " \
                         "spelling of reach: :#{verb.reach}" :
                         "#{verb} answered #{principal_label(as)} with #{own.length} row(s), none of " \
                         "which reached #{principal_label(and_not)} (declared reach: #{verb.reach})",
              details: { verb: verb.name, reach: verb.reach, own: own, other: other,
                         refused: refused },
            )
          else
            Conformance.fail(
              :principal_scope, subject: verb.name,
              message: "#{verb} is declared `reach: :#{verb.reach}` but leaked #{leaked.length} " \
                       "row(s) belonging to #{principal_label(as)} into #{principal_label(and_not)}'s answer: " \
                       "#{leaked.first(3).inspect}. Scope the handler to the calling principal.",
              details: { verb: verb.name, reach: verb.reach, leaked: leaked },
            )
          end
        end

        # The verb by name, or a failing Outcome listing the declared ones.
        def find_verb(origin, name)
          wanted = name.to_s
          found  = origin.verbs.find { |verb| verb.name == wanted }
          return found if found

          known = origin.verbs.map(&:name).sort
          Conformance.fail(
            :unknown_verb, subject: wanted,
            message: "no verb named #{wanted.inspect} is declared by this origin. " \
                     "Declared: #{known.empty? ? "(none at all)" : known.join(", ")}.",
            details: { asked: wanted, known: known },
          )
        end

        # Refusing the second principal outright scopes as well as narrowing does;
        # a 400 or 500 stays a failure.
        SCOPING_REFUSALS = [403, 404].freeze

        # «403 forbidden», or nil when the outcome is not a scoping refusal.
        def refusal_status(outcome)
          return nil unless outcome.failed?

          status = outcome.details[:error_status]
          return nil unless SCOPING_REFUSALS.include?(status)

          [status, outcome.details[:error_code]].compact.join(" ")
        end

        def principal_label(subject)
          subject.respond_to?(:id) ? "#{subject.class}(#{subject.id})" : subject.inspect
        end

        def arguments_for(verb, params)
          return normalize(params) unless params.equal?(EXAMPLE)

          normalize(verb.example_params || {})
        end

        def params_provenance(verb, params)
          return "" unless params.equal?(EXAMPLE)

          verb.example_params.nil? ? " (no arguments)" : " with its own example_params"
        end

        def route_problems(origin, verb, mount)
          path     = "#{mount}/#{verb.name}"
          problems = []
          found    = recognize(origin, path, verb.http_method)

          if found.nil?
            problems << "#{verb}: nothing answers #{verb.http_method} #{path} — declared and " \
                        "never routed, which is a 404 to every caller"
            return problems
          end

          endpoint = "#{found[:controller]}##{found[:action]}"
          if endpoint != verb.endpoint
            problems << "#{verb}: #{verb.http_method} #{path} reaches #{endpoint}, not " \
                        "#{verb.endpoint} — a route drawn straight at a handler bypasses " \
                        "authentication, the gate and the declared-input check"
          end

          routed_name = found[:kiosk_verb].to_s
          if routed_name != verb.name
            problems << "#{verb}: #{verb.http_method} #{path} hands the wire " \
                        "kiosk_verb: #{routed_name.inspect} — the path segment and the " \
                        "`defaults:` are two spellings of one name and must match"
          end

          other = recognize(origin, path, verb.other_http_method)
          if other && WIRE_ENDPOINTS.value?("#{other[:controller]}##{other[:action]}")
            problems << "#{verb}: #{path} also reaches the verb wire on " \
                        "#{verb.other_http_method} — the method follows the kind, so a " \
                        "#{verb.kind} answers #{verb.http_method} and nothing else"
          end

          problems
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
            pointer = error["data_pointer"].to_s
            "#{pointer.empty? ? "(root)" : pointer}: #{error["error"]}"
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
          when nil   then "nothing"
          else answer.class.name
          end
        end

        def describe_error(error)
          parts = ["#{error.class.name}: #{error.message}"]
          parts << "code=#{error.code}" if error.respond_to?(:code) && error.code
          parts << "hint: #{error.hint}" if error.respond_to?(:hint) && error.hint
          parts.join(", ")
        end
      end
    end
  end
end
