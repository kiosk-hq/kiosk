# frozen_string_literal: true

module Kiosk
  module Server
    # Delivery is ordered per origin (spec Section 8.5.5). The subscriptions
    # one upgrade URL declares form one group; a `subscribe` frame forms a
    # group of one. When every member is confirmed, the group replays the
    # members' tail in one ascending pass. Until then it holds their live
    # events, and after the replay it sends those it did not replay, in id order.
    class EventsReplay
      # One subscription in the group. `floor` is the cursor it replays after.
      Member = Struct.new(:group, :floor, :deliver) do
        delegate :confirmed, to: :group

        def live(event) = group.live(self, event)
      end

      def initialize(identity_key)
        @identity_key = identity_key
        @mutex = Mutex.new
        @members = []
        @confirmed = 0
        @open = true
        @held = []
        @replayed = false
      end

      # Adds a member while the group is open; nil after {#close}.
      # `deliver` transmits an event when the subscription wants it.
      def join(floor, &deliver)
        @mutex.synchronize do
          next unless @open

          Member.new(self, floor, deliver).tap { |member| @members << member }
        end
      end

      # No member joins after this.
      def close = settle { @open = false }

      def confirmed = settle { @confirmed += 1 }

      def live(member, event)
        @mutex.synchronize do
          @replayed ? member.deliver.call(event) : @held << [member, event]
        end
      end

      private

      def settle
        @mutex.synchronize do
          yield
          replay! if !@open && !@replayed && @members.any? && @confirmed == @members.size
        end
      end

      def replay!
        tail = Kiosk.configuration.event_store.since(@identity_key, @members.map(&:floor).min)
        tail.each { |event| offer(event) }
        release_held(tail.to_set { |event| event['id'] })
        @replayed = true
      end

      # A held event the replay already offered this member is not sent again.
      def release_held(replayed)
        @held.sort_by { |_, event| event['id'] }.each do |member, event|
          member.deliver.call(event) unless replayed.include?(event['id']) && event['id'] > member.floor
        end
        @held = nil
      end

      def offer(event)
        @members.each { |member| member.deliver.call(event) if event['id'] > member.floor }
      end
    end
  end
end
