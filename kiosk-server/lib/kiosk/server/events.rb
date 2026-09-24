# frozen_string_literal: true

module Kiosk
  module Server
    # The topic registry — the events half of what {Queries} and {Actions} are
    # for verbs, and deliberately the same shape.
    #
    # THE REUSE IS THE POINT. A topic declares `reach` from the same four values
    # a verb does, so an operator who has already decided who may READ a verb's
    # rows has answered the same question for the topic beside it. What a topic
    # adds is `subject_reachable`: a verb authorises A CALL, and a subscription
    # authorises A STANDING FEED, so the check has to be re-runnable without a
    # request — it takes the subject and the identity rather than reading
    # {CurrentRequest}, which is fiber-local and never reaches a socket callback.
    #
    # Process-global, like the two verb registries, and reset the same way in
    # tests. A topic is declared ONCE per origin: a second declaration of one
    # name is a bug rather than an override, because a name is one wire name and
    # one payload shape.
    module Events
      # Declared per topic and not defaultable. `description` carries semantics
      # as prose and `payload_schema` carries shape, for the reason the wire
      # already requires `output_schema` on every verb: with neither, a
      # subscriber cannot learn what a message contains without receiving one
      # and observing what arrived.
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

          # RE-REGISTERING THE SAME DECLARATION IS A NO-OP, and that is not a
          # softening of the rule below. A class holds its topic declarations
          # and hands the SAME frozen hashes over on every `kiosk_register!`,
          # which the engine may run more than once per reload cycle — so
          # identity here means «this is the same declaration arriving again»,
          # not «two declarations that happen to look alike». Two controllers
          # declaring one name still differ in at least their
          # `subject_reachable` object, and a second declaration of a name with
          # a different shape is the bug this refusal is for.
          return if registry[name] == declaration

          if registry.key?(name)
            raise ArgumentError,
              "topic #{name.inspect} is already declared on this origin. A topic name is one " \
              "wire name and one payload shape; declare it once, on the controller that owns " \
              "the transition it reports."
          end

          registry[name] = declaration
        end

        # Drops one topic. The engine's `to_prepare` clears all three registries
        # and rebuilds them from `c.handlers`, so a topic REMOVED from a
        # controller leaves the catalogue on the next reload instead of
        # outliving the declaration that put it there.
        #
        # @return [void]
        def unregister(name) = registry.delete(name.to_s)

        # @return [Hash, nil] the declaration, or nil when nothing declared it
        def fetch(name) = registry[name.to_s]

        # @return [Array<String>] declared topic names, sorted
        def known = registry.keys.sort

        # What `GET <endpoint>/schema` publishes beside `queries` and `actions`.
        #
        # SYMBOL keys with STRING values, which is not a style choice: it is
        # exactly what {Queries.describe} and {Actions.describe} return, and all
        # three end up in one JSON document. Two key conventions inside one
        # document read identically on the wire and diverge the moment anything
        # in the suite compares them.
        #
        # `subject_reachable` is deliberately ABSENT. It is the operator's
        # authorisation rule rather than a fact about the wire; publishing the
        # predicate would describe to a caller where to look for a gap in it,
        # and a subscriber could not act on it either way — the operator runs
        # it, at subscribe time and again on the re-authorisation timer.
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
        # THE SCOPE IS NOT DERIVED FROM `reach`, and the separation is
        # deliberate. `reach` authorises a SUBSCRIPTION — may this identity hold
        # a feed of this topic at all — and is answered at the socket, where the
        # topic's `subject_reachable` can be re-run on a timer. This decides a
        # DELIVERY: who, concretely, is to be told about THIS transition, which
        # only the operation that made it knows. Conflating them would mean
        # recomputing a membership set inside a socket callback that has no
        # request to read it from.
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
            # The append is what makes the event RESUMABLE; the broadcast is
            # what makes it PROMPT. Both, in that order: a socket woken before
            # the row exists would hand out an id a reconnecting client could
            # not then ask for.
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
