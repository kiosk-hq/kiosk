# frozen_string_literal: true

module Kiosk
  module Server
    # The event-store contract, and the in-process implementation of it: a Hash
    # and a Mutex in ONE process.
    #
    # == This is the test implementation, and a deployed origin may not use it
    #
    # It is what `Kiosk.configuration.event_store` falls back to when an operator
    # sets nothing, and it is correct for the suite and for a single-process
    # development boot and for nothing that is deployed. A deployed origin sets
    # {EventStores::ActiveRecord}, which `rails generate kiosk:install` writes
    # into the initializer; the engine refuses to boot a production origin that
    # declares a topic and leaves this default in place, and
    # {Kiosk::Server::Engine.ephemeral_event_store_error} is the refusal it
    # prints — that message is where the reason lives.
    #
    # == The seam
    #
    # Same shape as `pow_spent_store` and `revocation_store`: a plain object
    # swapped in an initializer, no model class, nothing in ActiveRecord touched
    # until an operation runs. Four methods — #append, #since, #head and
    # #truncated? — and an implementation that answers them is a valid store
    # however it holds its rows. #prune_before is this store's own.
    #
    # == An identity_key is a user_id, not an agent_id
    #
    # A human's second assistant sees the same stream; keying the tail on the
    # agent would hand a newly linked assistant an empty history of its human's
    # own orders. A revoked assistant is stopped at the socket, which re-verifies
    # on a timer and closes: revocation is about who may hold a connection, not
    # about whose events exist.
    class EventStore
      def initialize
        @mutex  = Mutex.new
        @seq    = 0
        @by_key = Hash.new { |hash, key| hash[key] = [] }
        @floor  = 0
      end

      # Append one event to one identity's tail and assign it the origin's next
      # id. ONE counter for the whole origin — not one per identity and not one
      # per topic — because that is what lets a single cursor resume every
      # subscription on a socket with one integer comparison.
      #
      # @param identity_key [String] a user_id
      # @param event [Hash] string-keyed, WITHOUT "id" — this assigns it
      # @return [Integer] the assigned id
      def append(identity_key, event)
        @mutex.synchronize do
          @seq += 1
          @by_key[identity_key.to_s] << event.merge("id" => @seq).freeze
          @seq
        end
      end

      # @param id [Integer] the caller's cursor; events at or below it are theirs already
      # @return [Array<Hash>] this identity's events with a greater id, ascending
      def since(identity_key, id)
        @mutex.synchronize do
          @by_key[identity_key.to_s].select { |event| event["id"] > id.to_i }
        end
      end

      # @return [Integer] the origin's current maximum id, 0 on a fresh origin
      def head = @mutex.synchronize { @seq }

      # "I cannot prove you saw everything." True when an id ABOVE the caller's
      # cursor has been pruned — the one condition that makes a subscriber
      # re-read current state through the ordinary verb, once, and then
      # continue on the stream.
      #
      # So the boundary is `@floor > id + 1`, not `id < @floor`: a cursor one
      # BELOW the floor is caught up, because everything after it survived.
      # {EventStores::ActiveRecord} is the reference for this question — it is
      # what a deployed origin runs — and it asks it that way.
      def truncated?(_identity_key, id)
        @mutex.synchronize { @floor > id.to_i + 1 }
      end

      # Drop everything below +id+ and remember that we did. The ActiveRecord
      # store prunes on a 24-hour clock instead; here it is what the suite uses
      # to reach the truncated branch deterministically.
      def prune_before(id)
        @mutex.synchronize do
          @floor = id.to_i
          @by_key.each_value { |tail| tail.reject! { |event| event["id"] < id.to_i } }
        end
      end
    end
  end
end
