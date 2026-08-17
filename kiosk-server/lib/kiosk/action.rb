# frozen_string_literal: true

require "kiosk/server/handler_mixin"

module Kiosk
  # Include into a controller of YOUR choosing to declare Kiosk **actions** —
  # the verbs an assistant invokes with `POST <mount>/run`. (`run` is the verb,
  # an action is the noun: you *run* an *action*.)
  #
  #   class Kiosk::OrdersController < ApplicationController   # your base class
  #     include Kiosk::Action
  #
  #     description "Places a grocery order for the assistant's human and " \
  #                 "reserves the chosen delivery window. Returns the order " \
  #                 "and what it will cost; nothing is charged until `pay`."
  #     input_schema type: "object", additionalProperties: false,
  #                  properties: {
  #                    items:            { type: "array", items: { type: "object" } },
  #                    delivery_slot_id: { type: "integer" },
  #                  },
  #                  required: %w[items delivery_slot_id]
  #     output_schema type: "object",
  #                   properties: { order_id: { type: "string" },
  #                                 total_cents: { type: "integer" } }
  #     example_params({ items: [{ sku: "MILK-1L", quantity: 2 }], delivery_slot_id: 3 })
  #     def create_order
  #       order = Orders::Place.call(user_id: kiosk_identity.user_id, params: params)
  #       render json: { order_id: order.id, total_cents: order.total_cents }
  #     end
  #   end
  #
  # Kiosk imposes no superclass — the include is the whole contract. Each
  # declared method is registered in {Kiosk::Server::Actions} and dispatched
  # through Rails' own `Controller.action(…)`, so filters, `rescue_from` and
  # `params` all behave as they do anywhere else in the app. Name the class in
  # `Kiosk.configuration.handlers` — that list is how the engine finds it, and
  # since T-081 it is the only way in.
  #
  # See {Kiosk::Server::HandlerMixin} for the macros, and {Kiosk::Query} for
  # the read side.
  module Action
    def self.included(base)
      Kiosk::Server::HandlerMixin.install(base, kind: :action)
    end
  end
end
