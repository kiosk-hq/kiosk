# frozen_string_literal: true

module Kiosk
  module TestHelpers
    module Conformance
      module Checks
        # Every declared verb is routed under its own name to the action that answers it.
        module Routes
          extend Helpers

          module_function

          def call(origin)
            verbs = origin.verbs
            return no_verbs if verbs.empty?

            mount    = origin.mount_path.to_s.chomp('/')
            problems = verbs.flat_map { |verb| problems_for(origin, verb, mount) }
            problems.empty? ? routed(verbs, mount) : unrouted(verbs, mount, problems)
          end

          def no_verbs
            Conformance.fail(
              :routes,
              message: 'this origin declares no verbs at all, so there is nothing to route. ' \
                       'Either app/controllers/kiosk holds no handler controller, ' \
                       'or the registry was read before the engine populated it — build the ' \
                       'origin inside the example, not at file load.'
            )
          end

          def routed(verbs, mount)
            Conformance.pass(
              :routes,
              message: "all #{verbs.length} declared verbs are routed under #{mount}/ " \
                       'with the method their kind requires',
              details: { verbs: verbs.map(&:name), mount_path: mount }
            )
          end

          def unrouted(verbs, mount, problems)
            Conformance.fail(
              :routes,
              message: "#{problems.length} of this origin's #{verbs.length} declared verbs are " \
                       "not routed as their kind requires:\n  - #{problems.join("\n  - ")}",
              details: { problems: problems, verbs: verbs.map(&:name), mount_path: mount }
            )
          end

          def problems_for(origin, verb, mount)
            path  = "#{mount}/#{verb.name}"
            found = recognize(origin, path, verb.http_method)
            return [not_routed(verb, path)] if found.nil?

            [wrong_endpoint(verb, path, found), wrong_name(verb, path, found),
             other_method(origin, verb, path)].compact
          end

          def not_routed(verb, path)
            "#{verb}: nothing answers #{verb.http_method} #{path} — declared and " \
              'never routed, which is a 404 to every caller'
          end

          def wrong_endpoint(verb, path, found)
            endpoint = "#{found[:controller]}##{found[:action]}"
            return if endpoint == verb.endpoint

            "#{verb}: #{verb.http_method} #{path} reaches #{endpoint}, not " \
              "#{verb.endpoint} — a route drawn straight at a handler answers " \
              '404 to every caller; name the verb in the `kiosk` block'
          end

          def wrong_name(verb, path, found)
            routed_name = found[:kiosk_verb].to_s
            return if routed_name == verb.name

            "#{verb}: #{verb.http_method} #{path} hands the wire " \
              "kiosk_verb: #{routed_name.inspect} — the path segment and the " \
              '`defaults:` are two spellings of one name and must match'
          end

          def other_method(origin, verb, path)
            other = recognize(origin, path, verb.other_http_method)
            return unless other && other[:kiosk_verb].to_s == verb.name

            "#{verb}: #{path} also reaches the verb on " \
              "#{verb.other_http_method} — the method follows the kind, so a " \
              "#{verb.kind} answers #{verb.http_method} and nothing else"
          end
        end
      end
    end
  end
end
