# frozen_string_literal: true

# The shop's shelf.
module Kiosk
  class CatalogController < ActionController::API
    include Kiosk::Handler

    kind :query
    description 'The products in stock now, at the price a cart is signed at. Alcohol is marked ' \
                '`age_restricted`: `create_order` takes it only after an 18+ check (`request_kyc`).'
    input_schema type: 'object', additionalProperties: false, properties: {}, required: []
    output_schema type: 'array',
                  description: 'In-stock products, by name.',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      sku: { type: 'string', description: "The product's handle in a cart." },
                      name: { type: 'string' },
                      price_cents: { type: 'integer', description: 'EUR cents.' },
                      price_eur: { type: 'string', description: 'The price as a human reads it, e.g. "€4.49".' },
                      currency: { type: 'string' },
                      low: { type: 'boolean', description: 'Present when stock is running out.' },
                      age_restricted: { type: 'boolean', description: 'Present on alcohol.' }
                    },
                    required: %w[sku name price_cents price_eur currency]
                  }
    example_params({})
    example_row({
                  sku: 'sourdough-bread', name: 'Sourdough Bread', price_cents: 449,
                  price_eur: '€4.49', currency: 'eur'
                })
    def catalog
      @products = Product.in_stock.order(:name)
    end
  end
end
