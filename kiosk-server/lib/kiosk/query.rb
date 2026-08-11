# frozen_string_literal: true

require "kiosk/server/handler_mixin"

module Kiosk
  # Include into a controller of YOUR choosing to declare Kiosk **queries** —
  # the sanctioned read surface an assistant reaches with `POST <mount>/query`.
  # An agent supplies a query NAME and params, never SQL.
  #
  #   class Kiosk::CatalogController < ApplicationController   # your base class
  #     include Kiosk::Query
  #
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
  #   end
  #
  # Kiosk imposes no superclass — the include is the whole contract. Each
  # declared method is registered in {Kiosk::Server::Queries} and dispatched
  # through Rails' own `Controller.action(…)`; it runs inside the wire's
  # GUC-scoped transaction, so per-principal scoping (and RLS, where the
  # operator opted in) applies exactly as it does to a registered block.
  #
  # A large result opts into cursor pagination with `render_kiosk_page(rows,
  # next_cursor:)` instead of `render json:`.
  #
  # See {Kiosk::Server::HandlerMixin} for the macros, and {Kiosk::Action} for
  # the write side.
  module Query
    def self.included(base)
      Kiosk::Server::HandlerMixin.install(base, kind: :query)
    end
  end
end
