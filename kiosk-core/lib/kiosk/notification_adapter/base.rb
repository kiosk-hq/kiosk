# frozen_string_literal: true

module Kiosk
  module NotificationAdapter
    # Abstract base for provider → user notification transport adapters.
    # See design spec §5.8 «Provider → User notifications».
    #
    # The default transport in v1.0 is `/kiosk/events` NDJSON polling
    # (Tier 2), served directly by kiosk-server. Adapters here are for
    # Tier 1 push delivery (MCP `notifications/*`) or Tier 3 out-of-band
    # delivery (email / SMS fallback), post-v1.0.
    class Base
      # Deliver an event to subscribers of the user's stream.
      #
      # @param event [Kiosk::Event]
      # @return [Boolean] true if accepted for delivery
      def notify(_event)
        raise NotImplementedError, "#{self.class}#notify must be implemented by the adapter"
      end
    end
  end
end
