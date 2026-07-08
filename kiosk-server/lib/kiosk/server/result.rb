# frozen_string_literal: true

module Kiosk
  module Server
    # Success-side envelope returned from {Executor} and serialised by
    # {WireController}. Errors use {Errors::Base#to_envelope}.
    #
    # `kind` distinguishes the payload shape:
    #
    #   :rows   — SQL result rows (Array<Hash>); serialised under `rows`
    #   :value  — single value returned by an Action; under `value`
    #   :stream — streaming events (NDJSON); under `events`
    #
    # `query_id` is an optional opaque correlation id for log lookup
    # (spec §5.2 «code, hint, query_id»).
    Result = Data.define(:kind, :payload, :query_id) do
      KINDS = %i[rows value stream].freeze

      def initialize(kind:, payload:, query_id: nil)
        kind = kind.to_sym
        unless KINDS.include?(kind)
          raise ArgumentError, "kind must be one of #{KINDS.inspect}, got #{kind.inspect}"
        end

        super(kind: kind, payload: payload, query_id: query_id)
      end

      def ok? = true

      def http_status = 200

      def to_envelope
        envelope = { ok: true, kind: kind }
        envelope[:query_id] = query_id if query_id
        envelope[payload_key] = payload
        envelope
      end

      private

      def payload_key
        case kind
        when :rows   then :rows
        when :value  then :value
        when :stream then :events
        end
      end
    end
  end
end
