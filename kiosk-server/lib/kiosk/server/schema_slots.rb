# frozen_string_literal: true

module Kiosk
  module Server
    # Data-derived descriptor slots: a proc in a declaration
    # (`enum: -> { Category.pluck(:slug) }`) is resolved lazily, memoized, and
    # re-resolved every {REFRESH_SECONDS}. An origin with no proc pays nothing.
    module SchemaSlots
      # Not `kind` or `wire_name`: those are fixed when the route is drawn.
      RESOLVABLE_SLOTS = %i[input_schema output_schema example_params example_row].freeze

      # Matches {Headers::SHORT_MAX_AGE}, the pointer document's lifetime.
      REFRESH_SECONDS = 60

      MAX_DEPTH = 32

      MUTEX = Mutex.new

      class << self
        # `0` or less re-resolves on every read.
        def refresh_seconds
          defined?(@refresh_seconds) && !@refresh_seconds.nil? ? @refresh_seconds : REFRESH_SECONDS
        end

        attr_writer :refresh_seconds

        # Inspects, never calls.
        def dynamic?(value, depth = 0)
          return false if depth > MAX_DEPTH

          case value
          when Proc  then true
          when Hash  then value.any? { |_key, member| dynamic?(member, depth + 1) }
          when Array then value.any? { |member| dynamic?(member, depth + 1) }
          else false
          end
        end

        # Latching: one dynamic declaration puts every verb on the resolving path.
        def note_declaration(slots)
          return true if dynamic_declarations?

          @dynamic = RESOLVABLE_SLOTS.any? { |slot| dynamic?(slots[slot]) }
        end

        def dynamic_declarations?
          defined?(@dynamic) ? !!@dynamic : false
        end

        # Monotonic, so a stepped wall clock does not move it.
        def epoch
          return 0 unless dynamic_declarations?

          seconds = refresh_seconds.to_f
          now     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return now if seconds <= 0

          (now / seconds).floor
        end

        # Double-checked under {MUTEX}, so a proc runs once per key per epoch.
        # The cache is replaced, never mutated, so the unlocked read is safe.
        def descriptor(scope, name, entry)
          return yield unless dynamic_declarations?

          key       = [scope, name.to_s].freeze
          now_epoch = epoch
          hit       = cache[key]
          return hit[:value] if fresh?(hit, entry, now_epoch)

          MUTEX.synchronize do
            hit = cache[key]
            return hit[:value] if fresh?(hit, entry, now_epoch)

            value = resolve(yield).freeze
            @cache = cache.merge(
              key => { value: value, entry: entry, epoch: now_epoch }.freeze,
            ).freeze
            value
          end
        end

        def resolve(value, depth = 0)
          raise ArgumentError, "kiosk: descriptor slot nests procs more than #{MAX_DEPTH} deep" if depth > MAX_DEPTH

          case value
          when Proc  then resolve(value.call, depth + 1)
          when Hash  then dynamic?(value) ? value.transform_values { |m| resolve(m, depth + 1) } : value
          when Array then dynamic?(value) ? value.map { |m| resolve(m, depth + 1) } : value
          else value
          end
        end

        # Called before the registry is rebuilt: a reload may remove the only proc.
        def reset!
          MUTEX.synchronize do
            @cache   = {}.freeze
            @dynamic = false
          end
          self
        end

        private

        def fresh?(hit, entry, now_epoch)
          !hit.nil? && hit[:epoch] == now_epoch && hit[:entry].equal?(entry)
        end

        def cache
          @cache ||= {}.freeze
        end
      end
    end
  end
end
