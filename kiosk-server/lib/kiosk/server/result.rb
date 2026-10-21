# frozen_string_literal: true

module Kiosk
  module Server
    # The executor's internal carrier for a successful call; only {#to_payload}
    # reaches the protocol, as the body.
    class Result < Data.define(:kind, :payload, :next_cursor, :total)
      KINDS = %i[rows value].freeze

      def initialize(kind:, payload:, next_cursor: nil, total: nil)
        kind = kind.to_sym
        raise ArgumentError, "kind must be one of #{KINDS.inspect}, got #{kind.inspect}" unless KINDS.include?(kind)
        raise ArgumentError, "next_cursor is only valid on a :rows result (got #{kind.inspect})" if next_cursor && kind != :rows
        raise ArgumentError, "total is only valid on a :rows result (got #{kind.inspect})" if total && kind != :rows

        super
      end

      def http_status = 200

      # Verbatim, with no envelope; a page's facts travel as headers (§8.2, §8.4).
      def to_payload = payload
    end
  end
end
