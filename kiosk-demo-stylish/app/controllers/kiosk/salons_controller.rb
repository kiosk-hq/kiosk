# frozen_string_literal: true

# The salons this front desk books for.
class Kiosk::SalonsController < ApplicationController
  include Kiosk::Handler

  kind :query
  description "Every salon this front desk books for, with the time zone its chairs keep."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "Every salon.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    salon_id: { type: "integer", description: "Pass to book_appointment as `salon_id`." },
                    name:     { type: "string", description: "Salon name." },
                    timezone: { type: "string",
                                description: "The salon's IANA zone; an hour the human names is an hour on this clock." },
                  },
                  required: %w[salon_id name timezone],
                }
  def salons
    render json: Salon.order(:id).map { |salon| { salon_id: salon.id, name: salon.name, timezone: salon.timezone } }
  end
end
