# frozen_string_literal: true

module Kiosk
  module Server
    # The in-process event store for tests and one-process development; production refuses it once
    # a topic is declared. Tails are keyed by user_id, so every assistant of one human shares one.
    class EventStore
      def initialize
        @mutex  = Mutex.new
        @seq    = 0
        @by_key = Hash.new { |hash, key| hash[key] = [] }
        @floor  = 0
      end

      # One id counter per origin, so one cursor resumes every subscription on a socket.
      # `event` is string-keyed, without "id"; returns the assigned id.
      def append(identity_key, event)
        @mutex.synchronize do
          @seq += 1
          @by_key[identity_key.to_s] << event.merge("id" => @seq).freeze
          @seq
        end
      end

      # This identity's events after the cursor `id`, ascending.
      def since(identity_key, id)
        @mutex.synchronize do
          @by_key[identity_key.to_s].select { |event| event["id"] > id.to_i }
        end
      end

      # The origin's maximum id, 0 when empty.
      def head = @mutex.synchronize { @seq }

      # True when an id above the caller's cursor has been pruned; a cursor one
      # below the floor missed nothing.
      def truncated?(_identity_key, id)
        @mutex.synchronize { @floor > id.to_i + 1 }
      end

      def prune_before(id)
        @mutex.synchronize do
          @floor = id.to_i
          @by_key.each_value { |tail| tail.reject! { |event| event["id"] < id.to_i } }
        end
      end
    end
  end
end
