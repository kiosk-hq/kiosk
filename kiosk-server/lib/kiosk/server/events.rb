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
        def register(name:, reach:, description:, payload_schema:, subject_reachable:)
          name = name.to_s
          declaration = {
            name: name,
            reach: reach,
            description: description,
            payload_schema: payload_schema,
            subject_reachable: subject_reachable,
          }.freeze

          # The same declaration again (a reload) is a no-op.
          return if registry[name] == declaration

          if registry.key?(name)
            raise ArgumentError,
              "topic #{name.inspect} is already declared on this origin. A topic name is one " \
              "wire name and one payload shape; declare it once, on the controller that owns " \
              "the transition it reports."
          end

          registry[name] = declaration
        end

        def unregister(name) = registry.delete(name.to_s)

        def fetch(name) = registry[name.to_s]

        def known = registry.keys.sort

        # Published beside `queries` and `actions`; `subject_reachable` is the operator's rule, not wire.
        def catalog
          known.map do |name|
            declaration = registry[name]
            {
              name: declaration[:name],
              description: declaration[:description],
              reach: declaration[:reach].to_s,
              payload_schema: declaration[:payload_schema],
            }
          end
        end

        # Appends one event to the tail of every identity in `identity_scope`. `reach` authorises
        # subscribing; `identity_scope` names who is told about this transition.
        # @param identity_scope [Array<String>] user_ids; empty writes nothing
        # @return [Integer, nil] the id of the last append, nil for an empty scope
        def emit(topic:, data:, identity_scope:, subject: nil, occurred_at: nil)
          name = topic.to_s
          unless fetch(name)
            raise ArgumentError,
              "#{name.inspect} is not a declared topic on this origin. Declare it with " \
              "`topic #{name.to_sym.inspect} do … end` on the controller that owns the " \
              "transition it reports; known topics: " \
              "#{known.empty? ? "(none)" : known.join(", ")}."
          end

          event = {
            "topic" => name,
            "subject" => subject,
            "occurred_at" => (occurred_at || Time.now).utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "data" => data,
          }

          store = Kiosk.configuration.event_store
          Array(identity_scope).map do |identity_key|
            id = store.append(identity_key, event)
            # Append before broadcast, so every pushed id can be resumed from.
            EventsCable.broadcast(identity_key, event.merge("id" => id))
            id
          end.last
        end

        def reset! = registry.clear

        private

        def registry = (@registry ||= {})
      end
    end
  end
end
