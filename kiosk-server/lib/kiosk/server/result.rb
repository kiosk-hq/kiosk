# frozen_string_literal: true

module Kiosk
  module Server
    # What a query handler returns to paginate: this page's `rows`, an opaque
    # `next_cursor` (nil on the last page) and an optional `total` matching
    # count. The wire sends the last two as `Link` and `X-Total-Count` headers.
    Page = Data.define(:rows, :next_cursor, :total) do
      def initialize(rows:, next_cursor: nil, total: nil)
        super(rows: rows, next_cursor: next_cursor, total: total)
      end

      def truncated? = !next_cursor.nil?
    end

    # An offset cursor, published as a decimal integer in clear: a cursor
    # authorises nothing, and opacity is the client's contract, not the token's.
    # A present cursor that is not one this helper wrote is a 400.
    module Cursor
      OFFSET_RE = /\A[0-9]+\z/

      module_function

      def encode_offset(offset)
        offset.to_i.to_s
      end

      def decode_offset(cursor, default: 0)
        return default if cursor.nil? || cursor.to_s.empty?

        raw = cursor.to_s
        unless raw.match?(OFFSET_RE)
          raise Errors::BadRequest.new(
            "cursor #{raw.inspect} is not a cursor this endpoint issued",
            hint: "do not build a cursor: fetch the `Link: <…>; rel=\"next\"` target verbatim, " \
                  "or copy its `cursor` parameter byte for byte. Omit `cursor` for the first page.",
          )
        end

        Integer(raw, 10)
      end
    end

    # The executor's internal carrier for a successful call; only {#to_payload}
    # reaches the wire, as the body.
    Result = Data.define(:kind, :payload, :next_cursor, :total) do
      KINDS = %i[rows value].freeze

      def initialize(kind:, payload:, next_cursor: nil, total: nil)
        kind = kind.to_sym
        unless KINDS.include?(kind)
          raise ArgumentError, "kind must be one of #{KINDS.inspect}, got #{kind.inspect}"
        end
        if next_cursor && kind != :rows
          raise ArgumentError, "next_cursor is only valid on a :rows result (got #{kind.inspect})"
        end
        if total && kind != :rows
          raise ArgumentError, "total is only valid on a :rows result (got #{kind.inspect})"
        end

        super(kind: kind, payload: payload, next_cursor: next_cursor, total: total)
      end

      def http_status = 200

      # Verbatim, with no envelope; a page's facts travel as headers (§8.2, §8.4).
      def to_payload = payload
    end
  end
end
