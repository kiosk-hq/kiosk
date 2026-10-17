# frozen_string_literal: true

module Kiosk
  module Server
    # The topic registry, shaped like {Queries} and {Actions}. A topic takes
    # `reach` from the verbs' four values; `subject_reachable` takes the
    # subject and identity, because it is re-run on a socket with no request.
    module Events
      # Declared on every topic, as `output_schema` is on every verb.
      REQUIRED = %i[description payload_schema].freeze

      class << self
        # rubocop:disable-next Metrics/ParameterLists -- each keyword is one member of the published topic declaration
        def register(name:, reach:, description:, payload_schema:, subject_reachable:, examples: [])
          name = name.to_s
          declaration = { name:, reach:, description:, payload_schema:, examples:, subject_reachable: }.freeze

          # The same declaration again (a reload) is a no-op.
          return if registry[name] == declaration
          raise ArgumentError, already_declared(name) if registry.key?(name)

          registry[name] = declaration
        end

        def unregister(name) = registry.delete(name.to_s)

        def fetch(name) = registry[name.to_s]

        def known = registry.keys.sort

        # Published beside `queries` and `actions`; `subject_reachable` is the operator's rule, not wire.
        def catalog = known.map { |name| catalog_entry(registry[name]) }

        # Appends one event to the tail of every identity in `identity_scope`. `reach` authorises
        # subscribing; `identity_scope` names who is told about this transition.
        # @param identity_scope [Array<String>] user_ids; empty writes nothing
        # @return [Integer, nil] the id of the last append, nil for an empty scope
        def emit(topic:, data:, identity_scope:, subject: nil, occurred_at: nil)
          name = topic.to_s
          raise ArgumentError, undeclared(name) unless fetch(name)

          event = {
            'topic' => name,
            'subject' => subject,
            'occurred_at' => (occurred_at || Time.now).utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
            'data' => data
          }
          Array(identity_scope).map { |identity_key| append(identity_key, event) }.last
        end

        def reset! = registry.clear

        private

        def registry = (@registry ||= {})

        def catalog_entry(declaration)
          entry = { name: declaration[:name], description: declaration[:description],
                    reach: declaration[:reach].to_s, payload_schema: declaration[:payload_schema] }
          entry[:examples] = declaration[:examples] if declaration[:examples].any?
          entry
        end

        # Append before broadcast, so every pushed id can be resumed from.
        def append(identity_key, event)
          id = Kiosk.configuration.event_store.append(identity_key, event)
          EventsCable.broadcast(identity_key, event.merge('id' => id))
          id
        end

        def already_declared(name)
          "topic #{name.inspect} is already declared on this origin. A topic name is one " \
            'wire name and one payload shape; declare it once, on the controller that owns ' \
            'the transition it reports.'
        end

        def undeclared(name)
          "#{name.inspect} is not a declared topic on this origin. Declare it with " \
            "`topic #{name.to_sym.inspect} do … end` on the controller that owns the " \
            'transition it reports; known topics: ' \
            "#{known.empty? ? '(none)' : known.join(', ')}."
        end
      end
    end
  end
end
