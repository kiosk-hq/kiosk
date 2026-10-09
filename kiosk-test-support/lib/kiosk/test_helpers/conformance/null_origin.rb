# frozen_string_literal: true

require "kiosk/test_helpers/conformance/verb"

module Kiosk
  module TestHelpers
    module Conformance
      # A hand-built origin with no Rails, Postgres or engine; this gem's own
      # suite runs the checks against it. The origin contract:
      #
      #   #mount_path                       → String, e.g. "/kiosk"
      #   #verbs                            → Array<Verb>
      #   #recognize(path, method:)         → {controller:, action:, kiosk_verb:} or nil
      #   #call(name, kind:, params:, as:)  → the verb's answer, or raises
      #   #schema_errors(payload, schema:, verb:, kind:, slot:) → Array<String> (optional)
      class NullOrigin
        attr_reader :mount_path, :verbs, :calls

        # @param routes [Hash] `[method, path] => {controller:, action:, kiosk_verb:}`
        # @param answers [Hash] `[verb_name, principal]` or `verb_name` => answer; an Exception is raised
        def initialize(mount_path: "/kiosk", verbs: [], routes: nil, answers: {})
          @mount_path = mount_path
          @verbs      = verbs
          @routes     = routes || self.class.routes_for(mount_path, verbs)
          @answers    = answers
          @calls      = []
        end

        # The route table a correctly routed origin would have.
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
