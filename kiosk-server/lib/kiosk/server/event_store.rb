# frozen_string_literal: true

module Kiosk
  module Server
    # THE EVENT-STORE CONTRACT, and the in-process implementation of it.
    #
    # == This is the test implementation, and a deployed origin may not use it
    #
    # It IS what `Kiosk.configuration.event_store` falls back to when an
    # operator sets nothing — the suite and a one-process `rails server` want
    # exactly this store and want no database for it. What a DEPLOYED origin
    # must set is {EventStores::ActiveRecord}, which `rails generate
    # kiosk:install` writes into the initializer, and the engine refuses to
    # boot a production origin that declares a topic and leaves this default in
    # place ({Kiosk::Server::Engine.ephemeral_event_store_error}). So «the
    # default» and «what ships in front of a subscriber» are two different
    # answers here, and the difference between them is not a deployment
    # nicety. Two of the topics an operator declares are not
    # WAITS but SUBSCRIPTIONS: a delivery event arrives hours after the order,
    # a shared-list event arrives whenever somebody else gets round to it, and
    # nothing holds a socket across an assistant's sessions — in any harness, on
    # any runtime, because a turn-based agent has no process that outlives its
    # session. So for those topics the CURSOR is the delivery mechanism and the
    # socket is an optimisation over it: the subscriber records `max(id)` and
    # asks for everything after it when it next runs. A tail that is gone on
    # restart makes that question unanswerable rather than merely degraded, and
    # `truncated: true` becomes the permanent answer for exactly the topics
    # that have no other one.
    #
    # This implementation is therefore correct for the suite and for a
    # single-process development boot, and for nothing that is deployed.
    #
    # == The seam
    #
    # Same shape as `pow_spent_store` and `revocation_store`: a plain object
    # swapped in an initializer, no model class, nothing in ActiveRecord touched
    # until an operation runs. Four methods, and an implementation that answers
    # them is a valid store however it holds its rows.
    #
    # == An identity_key is a user_id, not an agent_id
    #
    # A human's second assistant must see the same stream — keying the tail on
    # the agent would hand a newly linked assistant an empty history of its
    # human's own orders. A REVOKED assistant is stopped at the socket
    # (the connection re-verifies on a timer and closes), which is the right
    # place for it: revocation is about who may hold a connection, not about
    # whose events exist.
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

      # "I cannot prove you saw everything." True when rows between the caller's
      # cursor and what is still retained have been pruned — the one condition
      # that makes a subscriber re-read current state through the ordinary verb,
      # once, and then continue on the stream.
      #
      # A cursor AT head is never truncated, including on an empty origin: there
      # is nothing between it and what we hold.
      def truncated?(_identity_key, id)
        @mutex.synchronize { id.to_i < @floor }
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
