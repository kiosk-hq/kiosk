# frozen_string_literal: true

module Kiosk
  module Server
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
            hint: 'do not build a cursor: fetch the `Link: <…>; rel="next"` target verbatim, ' \
                  'or copy its `cursor` parameter byte for byte. Omit `cursor` for the first page.'
          )
        end

        Integer(raw, 10)
      end
    end
  end
end
