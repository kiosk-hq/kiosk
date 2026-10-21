# frozen_string_literal: true

module Kiosk
  module Server
    # What a query handler returns to paginate: this page's `rows`, an opaque
    # `next_cursor` (nil on the last page) and an optional `total` matching
    # count. The protocol sends the last two as `Link` and `X-Total-Count` headers.
    Page = Data.define(:rows, :next_cursor, :total) do
      def initialize(rows:, next_cursor: nil, total: nil)
        if !next_cursor.nil? && next_cursor.to_s.empty?
          raise ArgumentError, 'next_cursor is empty. Pass nil on the last page: a next link with an ' \
                               'empty cursor leads back to page one (§8.4).'
        end

        super
      end
    end
  end
end
