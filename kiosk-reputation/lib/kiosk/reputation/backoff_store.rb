# frozen_string_literal: true

module Kiosk
  module Reputation
    # In-process remaining-grant counter for {Policies::Backoff}. Per worker only:
    # a multi-process deployment passes a shared store with the same `grant` and
    # an atomic `consume`.
    class BackoffStore
      def initialize
        @counter = {}
        @mutex   = Mutex.new
      end

      def grant(key, n)
        @mutex.synchronize { @counter[key] = n.to_i }
        nil
      end

      # True when a grant was available and consumed.
      def consume(key)
        @mutex.synchronize do
          remaining = @counter[key].to_i
          if remaining.positive?
            @counter[key] = remaining - 1
            true
          else
            false
          end
        end
      end
    end
  end
end
