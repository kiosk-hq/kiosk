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
        # @param name [String, Symbol] a wire name, validated by the caller
        # @param reach [Symbol] one of {HandlerMixin::REACHES}
        # @param subject_reachable [#call, nil] `(subject, identity) -> Boolean`
        # @return [void]
        def register(name:, reach:, description:, payload_schema:, subject_reachable:)
          name = name.to_s
          declaration = {
            name: name,
            reach: reach,
            description: description,
            payload_schema: payload_schema,
            subject_reachable: subject_reachable,
          }.freeze

          # The same declaration arriving again (a reload) is a no-op; a
          # different one under a declared name is refused.
          return if registry[name] == declaration

          if registry.key?(name)
            raise ArgumentError,
              "topic #{name.inspect} is already declared on this origin. A topic name is one " \
              "wire name and one payload shape; declare it once, on the controller that owns " \
              "the transition it reports."
          end

          registry[name] = declaration
        end

        # @return [void]
        def unregister(name) = registry.delete(name.to_s)

        # @return [Hash, nil] the declaration, or nil when nothing declared it
        def fetch(name) = registry[name.to_s]

        # @return [Array<String>] declared topic names, sorted
        def known = registry.keys.sort

        # What `GET <endpoint>/schema` publishes beside `queries` and
        # `actions`, keyed like them. `subject_reachable` is the operator's
        # rule, not wire, so it is not published.
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

        # Append one event to the tail of every identity in +identity_scope+ —
        # the ONE line an operator writes at the transition.
        #
        #   Kiosk::Server::Events.emit(
        #     topic: :todo, subject: list_id, identity_scope: members_of(list_id),
        #     data: { "todo_id" => todo.id, "done" => true, "action" => "completed" },
        #   )
        #
        # `reach` authorises a subscription; `identity_scope` names who is told
        # about this transition, which only the operation that made it knows.
        #
        # @param identity_scope [Array<String>] user_ids; empty writes nothing
        # @param occurred_at [Time, nil] defaults to now, rendered ISO 8601 UTC
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
