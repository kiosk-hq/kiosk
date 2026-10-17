# frozen_string_literal: true

module Kiosk
  module Server
    # What a query handler returns to paginate: this page's `rows`, an opaque
    # `next_cursor` (nil on the last page) and an optional `total` matching
    # count. The wire sends the last two as `Link` and `X-Total-Count` headers.
    Page = Data.define(:rows, :next_cursor, :total) do
      def initialize(rows:, next_cursor: nil, total: nil)
        super
      end
    end
  end
end
