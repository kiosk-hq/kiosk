# frozen_string_literal: true

module Kiosk
  module Server
    # The in-process event store: the default for tests and a one-process
    # development boot. A deployed origin sets {EventStores::ActiveRecord}; the
    # engine refuses to boot production with this one and a declared topic.
    #
    # A store answers #append, #since, #head and #truncated?; #prune_before is
    # this one's own. The tail is keyed by user_id, so every assistant of one
    # human sees the same stream.
    class EventStore
      def initialize
        @mutex  = Mutex.new
        @seq    = 0
        @by_key = Hash.new { |hash, key| hash[key] = [] }
        @floor  = 0
      end

      # Appends to one identity's tail under the origin's next id — one counter
      # for the origin, so one cursor resumes every subscription on a socket.
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

      # True when an id above the caller's cursor has been pruned; a cursor one
      # below the floor missed nothing.
      def truncated?(_identity_key, id)
        @mutex.synchronize { @floor > id.to_i + 1 }
      end

      # Drops everything below +id+.
      def prune_before(id)
        @mutex.synchronize do
          @floor = id.to_i
          @by_key.each_value { |tail| tail.reject! { |event| event["id"] < id.to_i } }
        end
      end
    end
  end
end
