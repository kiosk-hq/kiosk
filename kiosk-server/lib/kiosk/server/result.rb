# frozen_string_literal: true

module Kiosk
  module Server
    # A paginated slice of query rows. A `query` handler that returns a large
    # list opts into cursor pagination by returning one of these instead of a
    # bare Array (T-042 / K-452 / ADR-0021).
    #
    #   rows        — the (truncated) Array<Hash> for THIS page.
    #   next_cursor — an OPAQUE String the assistant echoes back in the next
    #                 request's `cursor` param to fetch the following page.
    #                 PRESENT (non-nil) means the result was truncated (more
    #                 rows exist); nil/absent means this is the last page.
    #
    # The cursor is opaque BY CONTRACT: the assistant never parses it, it only
    # round-trips it. A handler is free to encode an offset, a keyset token, or
    # anything else behind it. {Cursor} provides a base64 offset helper for the
    # common case; a handler MAY use its own scheme.
    #
    # Pagination applies to LIST results only. Single-object/action/pay results
    # (kind: :value) never carry a cursor.
    Page = Data.define(:rows, :next_cursor) do
      def initialize(rows:, next_cursor: nil)
        super(rows: rows, next_cursor: next_cursor)
      end

      # True when the result was truncated (more rows exist beyond this page).
      def truncated? = !next_cursor.nil?
    end

    # Opaque-cursor helper for the common offset-pagination case. A handler MAY
    # ignore this and roll its own opaque token — the wire contract only requires
    # that whatever the handler emits as `next_cursor` be echoed back verbatim in
    # the next request's `cursor` param.
    #
    #   Cursor.encode_offset(40)  # => "b2Zmc2V0OjQw"  (opaque to the client)
    #   Cursor.decode_offset("b2Zmc2V0OjQw", default: 0) # => 40
    #
    # decode_offset is deliberately lenient: a malformed/absent cursor decodes to
    # `default` (0) rather than raising, so a garbage `cursor` param yields the
    # first page instead of a 500.
    module Cursor
      PREFIX = "offset:"

      module_function

      def encode_offset(offset)
        require "base64"
        Base64.urlsafe_encode64("#{PREFIX}#{offset.to_i}", padding: false)
      end

      def decode_offset(cursor, default: 0)
        return default if cursor.nil? || cursor.to_s.empty?

        require "base64"
        decoded = Base64.urlsafe_decode64(cursor.to_s)
        return default unless decoded.start_with?(PREFIX)

        Integer(decoded.delete_prefix(PREFIX))
      rescue ArgumentError
        default
      end
    end

    # Success-side envelope returned from {Executor} and serialised by
    # {WireController}. Errors use {Errors::Base#to_envelope}.
    #
    # `kind` distinguishes the payload shape:
    #
    #   :rows   — SQL result rows (Array<Hash>); serialised under `rows`
    #   :value  — single value returned by an Action; under `value`
    #
    # `next_cursor` is OPTIONAL and only ever set on a :rows Result whose query
    # handler paginated (returned a {Page} with a next_cursor). When present it
    # is serialised as the top-level `next` envelope field — an opaque cursor the
    # assistant echoes back in `cursor` to fetch the following page. ABSENT means
    # the result is complete (ADR-0021 / T-042).
    #
    # The `:stream` kind (events, NDJSON) was removed with the `events` verb:
    # it was never a capability and had no producer.
    Result = Data.define(:kind, :payload, :next_cursor) do
      KINDS = %i[rows value].freeze

      def initialize(kind:, payload:, next_cursor: nil)
        kind = kind.to_sym
        unless KINDS.include?(kind)
          raise ArgumentError, "kind must be one of #{KINDS.inspect}, got #{kind.inspect}"
        end
        if next_cursor && kind != :rows
          raise ArgumentError, "next_cursor is only valid on a :rows result (got #{kind.inspect})"
        end

        super(kind: kind, payload: payload, next_cursor: next_cursor)
      end

      def ok? = true

      def http_status = 200

      def to_envelope
        envelope = { ok: true, kind: kind }
        envelope[payload_key] = payload
        # PRESENT `next` = truncated (more rows exist); ABSENT = complete. Only
        # emitted when the handler paginated, so every existing (non-paginating)
        # response is byte-for-byte unchanged.
        envelope[:next] = next_cursor unless next_cursor.nil?
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
