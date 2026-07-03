# frozen_string_literal: true

module Kiosk
  # Provider → user notification event.
  # See design spec §5.8 «Provider → User notifications».
  #
  # Carried over `/kiosk/events` as NDJSON (Tier 2 polling).
  # Tier 1 push delivery (post-v1.0) via NotificationAdapter.
  #
  # @!attribute [r] id
  #   Server-side unique event id.
  # @!attribute [r] user_id
  #   Recipient principal — RLS keys off this; user sees only own events.
  # @!attribute [r] kind
  #   Dotted event-kind string, e.g. `"booking.confirmed"`,
  #   `"order.partially_filled"`, `"refund.issued"`. Provider-defined
  #   namespace.
  # @!attribute [r] urgency
  #   One of `"low"`, `"normal"`, `"high"`, `"critical"`. Drives delivery
  #   tier selection in kiosk-server.
  # @!attribute [r] payload
  #   Hash of event-specific data. Opaque to Kiosk core; provider-defined.
  # @!attribute [r] expires_at
  #   Optional — when nil, the event lives until polled or buffer evicts it.
  # @!attribute [r] created_at
  #   Server timestamp at emit.
  Event = Data.define(:id, :user_id, :kind, :urgency, :payload, :expires_at, :created_at) do
    URGENCIES = %w[low normal high critical].freeze

    def initialize(id:, user_id:, kind:, urgency:, payload:, created_at:, expires_at: nil)
      raise ArgumentError, "id required"      if id.nil?
      raise ArgumentError, "user_id required" if user_id.nil?
      raise ArgumentError, "kind required"    if kind.nil? || kind.to_s.empty?

      urgency = urgency.to_s
      unless URGENCIES.include?(urgency)
        raise ArgumentError,
              "urgency must be one of #{URGENCIES.inspect}, got #{urgency.inspect}"
      end

      super(
        id:         id,
        user_id:    user_id,
        kind:       kind.to_s,
        urgency:    urgency,
        payload:    payload || {},
        expires_at: expires_at,
        created_at: created_at,
      )
    end
  end
end
