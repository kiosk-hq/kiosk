# frozen_string_literal: true

# Open restaurant tables.
module Kiosk
  class TablesController < ActionController::API
    include Kiosk::Handler

    kind :query
    description 'Open tables for the upcoming seatings that seat the party, across every restaurant. ' \
                'An empty answer means sold out; `book_table` books the row the human picks.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   party_size: { type: 'integer', minimum: 1,
                                 maximum: Booking::MAX_PARTY_SIZE,
                                 description: 'Number of guests.' },
                   neighborhood: { type: 'string', description: 'Lisbon neighbourhood, e.g. "Alfama".' },
                   time: { type: 'string', enum: Restaurant.seating_times,
                           description: "Seating time on the restaurant's clock." },
                   date: { type: 'string', format: 'date',
                           description: "Seating date on the restaurant's clock, today or one of the next 13 days. " \
                                        'With no date, the answer holds today and tomorrow.' }
                 },
                 required: ['party_size']
    output_schema type: 'array',
                  description: 'One row per open table and seating.',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      restaurant: { type: 'string', description: 'Restaurant name.' },
                      timezone_note: { type: 'string',
                                       description: 'Present only when your declared Kiosk-Timezone is on another ' \
                                                    "clock now: how far the restaurant's clock is from yours." },
                      neighborhood: { type: %w[string null], description: 'Lisbon neighbourhood.' },
                      cuisine: { type: %w[string null], description: 'Cuisine.' },
                      restaurant_table_id: { type: 'integer', description: 'The table; pass it to book_table.' },
                      table_label: { type: 'string', description: "The table's name at the restaurant." },
                      capacity: { type: 'integer', description: 'Seats at the table.' },
                      seating_label: { type: 'string', description: 'The seating as the human reads it, in the ' \
                                                                    "restaurant's zone, e.g. \"Sun 18 Oct, 20:00 (Europe/Lisbon)\"." },
                      seating_at: { type: 'string', description: "The seating with the restaurant's offset; pass it to book_table." }
                    },
                    required: %w[restaurant neighborhood cuisine restaurant_table_id table_label capacity
                                 seating_label seating_at]
                  }
    example_params({ party_size: 2, neighborhood: 'Alfama' })
    example_row({
                  restaurant: 'Tasca do Tejo', neighborhood: 'Alfama', cuisine: 'Portuguese tavern',
                  restaurant_table_id: 1, table_label: 'Window 6', capacity: 2,
                  seating_label: -> { Restaurant.seating_label(Restaurant.example_seating) },
                  seating_at: -> { Restaurant.example_seating.iso8601 }
                })
    def availability
      @search = TableSearch.new(params.permit(:party_size, :neighborhood, :date, :time))
      @search.validate!
    end
  end
end
