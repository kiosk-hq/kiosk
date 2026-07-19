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
    #
    # The `:stream` kind (events, NDJSON) was removed with the `events` verb:
    # it was never a capability and had no producer.
    Result = Data.define(:kind, :payload) do
      KINDS = %i[rows value].freeze

      def initialize(kind:, payload:)
        kind = kind.to_sym
        unless KINDS.include?(kind)
          raise ArgumentError, "kind must be one of #{KINDS.inspect}, got #{kind.inspect}"
        end

        super(kind: kind, payload: payload)
      end

      def ok? = true

      def http_status = 200

      def to_envelope
        envelope = { ok: true, kind: kind }
        envelope[payload_key] = payload
        envelope
      end

      private

      def payload_key
        case kind
        when :rows  then :rows
        when :value then :value
        end
      end
    end
  end
end
