# frozen_string_literal: true

require "json"

require "kiosk/test_helpers/conformance/outcome"
require "kiosk/test_helpers/conformance/verb"

module Kiosk
  module TestHelpers
    module Conformance
      # The four checks, as pure functions of an ORIGIN.
      #
      # Each takes an origin (see {Conformance} for the contract) and returns an
      # {Outcome}. None of them knows what a test framework is: the Minitest and
      # RSpec adapters turn an Outcome into a `flunk` or a matcher failure and
      # render its `message` verbatim, which is what makes the same fault read
      # identically in both.
      #
      # The four properties are the ones the protocol makes normative of an
      # origin — its routes resolve, a verb executes, a query answers the shape
      # it declared, and data access is scoped to the authenticated principal.
      # An operator cannot demonstrate conformance to a document without a way
      # to run its claims, and these are that way.
      module Checks
        # `params:` sentinel. The default is not `{}` — it is "the verb's own
        # `example_params` if it declared one, otherwise the empty object", so
        # the cheapest true assertion an adopter can write also executes the
        # example their descriptor publishes. Pass `params: {}` to mean the
        # empty object literally.
        EXAMPLE = :__kiosk_example_params__

        module_function

        # ── 1. ROUTES ───────────────────────────────────────────────────────
        #
        # Every declared verb has a route, that route reaches the wire's verb
        # controller under the name it was declared by, and the METHOD follows
        # the KIND: GET for a query, POST for an action.
        #
        # Since the engine stopped drawing a constrained catch-all pair for the
        # operator, a verb declared and never routed is a 404 to every caller
        # and is invisible to the origin's own tests unless one happens to call
        # that verb. This is the check that makes it visible.
        #
        # It asks the ROUTER, not a file: a verb declared by metaprogramming is
        # in the registry and in the route table, and both are what this reads.
        #
        # VACUITY ARM. An origin declaring no verbs at all FAILS. An empty
        # registry — the likeliest way for this whole suite to be green and mean
        # nothing — must not read as "all zero of my verbs are routed".
        def routes(origin)
          verbs = origin.verbs
          if verbs.empty?
            return Conformance.fail(
              :routes,
              message: "this origin declares no verbs at all, so there is nothing to route. " \
                       "Either no handler controller is named in `Kiosk.configuration.handlers`, " \
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

        # ── 2. VERB EXECUTES ────────────────────────────────────────────────
        #
        # Called with these arguments as this principal, the verb answers rather
        # than refusing. A refusal is reported with the wire code, the message
        # and the hint the error carried, because on this path those strings are
        # written for exactly this reader.
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

        # ── 3. THE ANSWER MATCHES THE DECLARED SHAPE ────────────────────────
        #
        # `output_schema` is REQUIRED of every verb and, with no response
        # envelope, is the ONLY machine-readable statement of what a call
        # returns. A descriptor that MIS-states the shape is worse than one that
        # says nothing: the assistant shapes its parse from it and never meets
        # the handler that disagrees.
        #
        # Arguments are checked against `input_schema` FIRST and reported
        # separately, because a failing example in a descriptor is a different
        # defect from a handler rendering the wrong shape, and telling them
        # apart is most of the value.
        #
        # A verb with no `output_schema` FAILS rather than skipping. Both
        # schemas are required of every verb and the mixin raises at class-body
        # load for a declaration missing either, so an absent one here means the
        # origin is not what it claims to be.
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

        # ── 4. DATA ACCESS IS SCOPED TO THE PRINCIPAL ───────────────────────
        #
        # `reach: :principal` is the default and the norm, and across a fleet it
        # is spelled nowhere — a declaration that says nothing means it. So the
        # strongest claim an origin makes about data access is the one it makes
        # by silence, and this is the check that executes it.
        #
        # The assertion is DISJOINTNESS, not emptiness, and it carries its own
        # positive control:
        #
        #   1. VACUITY ARM — if the first principal's answer is empty there is
        #      nothing to be scoped from, and the check FAILS. A verb that
        #      answers `[]` to everybody would otherwise pass while broken,
        #      which is the exact shape of a pattern that matches nothing and
        #      reads as coverage.
        #   2. DISJOINTNESS — no row the second principal sees may equal a row
        #      the first sees. Whole-row comparison, so it needs no id-column
        #      convention and no configuration.
        #   3. REACH AGREEMENT — a verb declared `published` is SUPPOSED to
        #      answer both principals the same, so asserting disjointness on it
        #      asserts the opposite of the descriptor. That is a failure naming
        #      the declared reach, so a verb whose reach was widened without its
        #      tests being revisited goes red.
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

        # ── internal ────────────────────────────────────────────────────────

        # The verb by name, or a failing Outcome naming what IS declared — a
        # typo in a test should be answerable without a schema round-trip, the
        # same courtesy the wire's own unknown-name hint extends to an agent.
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

        # The wire codes that mean «that is not yours», as a REFUSAL rather than
        # as a broken call.
        #
        # A verb may scope by narrowing its answer or by refusing outright, and
        # refusing is the STRONGER of the two — an origin that answers 404 to a
        # row it will not show does not even confirm that the row exists. So a
        # 403 or a 404 to the second principal is this check passing, not
        # failing. Nothing wider is accepted: a 400 means the arguments were
        # wrong, which is a defect in the test rather than scoping, and a 500 is
        # a defect in the handler; both must stay red.
        #
        # Read by STATUS and not by class, so this stays framework-agnostic and
        # holds for any origin whose refusals answer the wire's own codes.
        SCOPING_REFUSALS = [403, 404].freeze

        # The refusal an `executes` outcome carries, as «403 forbidden», or nil
        # when it did not fail or did not fail by refusing.
        def refusal_status(outcome)
          return nil unless outcome.failed?

          status = outcome.details[:error_status]
          return nil unless SCOPING_REFUSALS.include?(status)

          [status, outcome.details[:error_code]].compact.join(" ")
        end

        # How a principal is NAMED in a failure sentence.
        #
        # `inspect` on an ActiveRecord row prints every column, which buries the
        # sentence that matters under a fixture — measured on a real demo, where
        # a two-row leak rendered behind two full `#<User …>` dumps. A principal
        # is identified by its id; anything without one is inspected as before.
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
            # The engine appends a single-segment REFUSAL pair below the
            # operator's own routes, so a verb nobody drew is caught by that
            # rather than by nothing at all — and `recognize_path` then answers
            # a route instead of raising. It is still «declared and never
            # routed», and it is the commonest spelling of it, so it gets its
            # own sentence rather than the generic wrong-endpoint one.
            problems << if endpoint.include?("verb_refusal")
                          "#{verb}: nothing you drew answers #{verb.http_method} #{path} — " \
                          "the engine's own refusal route caught it, so every caller gets a " \
                          "404 for a verb this origin publishes"
                        else
                          "#{verb}: #{verb.http_method} #{path} reaches #{endpoint}, not " \
                          "#{verb.endpoint} — a route drawn straight at a handler bypasses " \
                          "authentication, the gate and the declared-input check"
                        end
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

        # Ask the origin's router. A router that raises for "no route" and one
        # that returns nil are both normal; neither is a check failure.
        def recognize(origin, path, http_method)
          origin.recognize(path, method: http_method)
        rescue StandardError
          nil
        end

        # Schema failures as a list of strings. An origin MAY answer this
        # itself — the engine-backed one does, so the test and the running
        # server apply the identical check rather than two implementations that
        # can disagree — and the fallback here is the same json_schemer call for
        # origins that do not.
        def schema_errors(origin, payload, schema, verb, slot)
          if origin.respond_to?(:schema_errors)
            return Array(origin.schema_errors(payload, schema: schema, verb: verb.name,
                                              kind: verb.kind, slot: slot))
          end

          require_schemer!
          JSONSchemer.schema(normalize(schema)).validate(normalize(payload)).map do |error|
            pointer = error["data_pointer"].to_s
            "#{pointer.empty? ? "(root)" : pointer}: #{error["error"]}"
          end
        end

        def require_schemer!
          return if defined?(JSONSchemer)

          require "json_schemer"
        rescue LoadError
          raise Errors::SchemaValidatorMissing
        end

        # The wire representation of a value: the same JSON round trip the
        # answer makes on its way to a caller, so a schema check here sees what
        # a caller sees rather than the Ruby objects behind it.
        def normalize(value)
          JSON.parse(JSON.generate([value])).first
        end

        # The comparable rows of an answer. A query answers an Array; an action
        # answers one object, which is a single "row" for the purpose of
        # disjointness.
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
