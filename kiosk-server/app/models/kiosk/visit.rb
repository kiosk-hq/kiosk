# frozen_string_literal: true

module Kiosk
  # A visit the operator fulfilled: a table honoured, an appointment kept. Its
  # value counts toward the customer's recent spend, so an operator that takes
  # no payment can still lower the proof-of-work toll for a returning customer.
  class Visit < ::ActiveRecord::Base
    def self.table_name = "#{Kiosk.configuration.schema}.visits"

    # Call it when the visit happens, with what the visit was worth.
    def self.record!(user_id:, value_cents:) = create!(user_id:, value_cents:)
  end
end
