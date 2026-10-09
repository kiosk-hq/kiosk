# frozen_string_literal: true

require "kiosk/server/handler_mixin"
require "kiosk/server/handler_registrations"

module Kiosk
  # Include into any controller to declare verbs: a query (`GET <mount>/<name>`)
  # or an action (`POST <mount>/<name>`). Handlers live in app/controllers/kiosk.
  #
  #   class Kiosk::BoardController < ApplicationController   # your base class
  #     include Kiosk::Handler
  #
  #     kind :query
  #     description "Lists what this shop has in stock right now, so the " \
  #                 "assistant can decide what to put in a basket."
  #     input_schema type: "object", additionalProperties: false,
  #                  properties: { q: { type: "string" } }
  #     output_schema type: "array",
  #                   items: { type: "object",
  #                            properties: { sku:         { type: "string" },
  #                                          price_cents: { type: "integer" } } }
  #     def catalog
  #       render json: Product.in_stock.search(params[:q]).as_json
  #     end
  #
  #     kind :action
  #     description "Places an order for the assistant's human. Returns the " \
  #                 "order and what it will cost; nothing is charged until `pay`."
  #     input_schema type: "object", additionalProperties: false,
  #                  properties: { items: { type: "array", items: { type: "object" } } },
  #                  required: %w[items]
  #     output_schema type: "object",
  #                   properties: { order_id:    { type: "string" },
  #                                 total_cents: { type: "integer" } }
  #     def create_order
  #       order = Orders::Place.call(user_id: kiosk_identity.user_id, params: params)
  #       render json: { order_id: order.id, total_cents: order.total_cents }
  #     end
  #   end
  module Handler
    def self.included(base)
      Kiosk::Server::HandlerMixin.install(base)
      Kiosk::Server::HandlerRegistrations.add(base)
    end
  end
end
