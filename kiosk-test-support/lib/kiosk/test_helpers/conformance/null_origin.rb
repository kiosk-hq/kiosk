# frozen_string_literal: true

require "kiosk/test_helpers/conformance/verb"

module Kiosk
  module TestHelpers
    module Conformance
      # A zero-dependency origin: no Rails, no Postgres, no engine. It is the
      # REFERENCE IMPLEMENTATION of the origin contract — the four methods below
      # are the whole of it — and it is what this gem's own suite runs the checks
      # against, exactly as {NullExecutor} is for the journey DSL.
      #
      # It is not a mock of an application. It is a hand-built origin: you give
      # it verbs, a route table and answers, and the checks cannot tell it from a
      # real one. That is the point — a check that only works against Rails would
      # be untestable without Rails, and a check nobody can test is not a check.
      #
      # ── The origin contract ─────────────────────────────────────────────────
      #
      #   #mount_path                            → String, e.g. "/kiosk"
      #   #verbs                                 → Array<Verb>
      #   #recognize(path, method:)              → Hash|nil with :controller,
      #                                            :action, :kiosk_verb
      #   #call(name, kind:, params:, as:)       → the verb's answer, or raises
      #
      # And one OPTIONAL method, which an origin implements when it has a better
      # validator than the checks' own:
      #
      #   #schema_errors(payload, schema:, verb:, kind:, slot:) → Array<String>
      class NullOrigin
        attr_reader :mount_path, :verbs, :calls

        # @param mount_path [String] where the wire is mounted
        # @param verbs [Array<Verb>] what this origin declares
        # @param routes [Hash] `[method, path] => {controller:, action:, kiosk_verb:}`
        # @param answers [Hash] `[verb_name, principal] => answer`, falling back
        #   to `verb_name => answer`. An answer that is an Exception is RAISED,
        #   which is how a refusal is expressed.
        def initialize(mount_path: "/kiosk", verbs: [], routes: nil, answers: {})
          @mount_path = mount_path
          @verbs      = verbs
          @routes     = routes || self.class.routes_for(mount_path, verbs)
          @answers    = answers
          @calls      = []
        end

        # The route table a correctly routed origin would have, derived from the
        # verbs themselves. A test that wants a BROKEN table passes its own.
        def self.routes_for(mount_path, verbs)
          verbs.each_with_object({}) do |verb, table|
            path = "#{mount_path.chomp("/")}/#{verb.name}"
            controller, action = verb.endpoint.split("#")
            table[[verb.http_method, path]] = {
              controller: controller, action: action, kiosk_verb: verb.name,
            }
          end
        end

        def recognize(path, method:)
          @routes[[method.to_s.upcase, path]]
        end

        def call(name, kind:, params:, as: nil)
          @calls << { name: name, kind: kind, params: params, as: as }
          answer = @answers.fetch([name, as]) { @answers.fetch(name, nil) }
          answer = answer.call(params: params, as: as) if answer.is_a?(Proc)
          raise answer if answer.is_a?(::Exception)

          answer
        end
      end
    end
  end
end
