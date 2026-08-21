# frozen_string_literal: true

require "kiosk/server/handler_mixin"

module Kiosk
  # Include into a controller of YOUR choosing to declare Kiosk **verbs** — the
  # sanctioned surface an assistant reaches under the mount. A verb is either a
  # QUERY (`GET <mount>/<name>`, a read) or an ACTION (`POST <mount>/<name>`, a
  # write), and each declaration says which it is with `kind`.
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
  #
  # ONE CONTROLLER MAY DECLARE BOTH, and the example above does. Which verb kind
  # reaches a handler is a property of the DECLARATION, not of the class, so a
  # resource an operator thinks of as one thing — a board you browse and post to
  # — is one controller. Split it when the domain splits, not because the
  # framework said so. ({Kiosk::Server::HandlerMixin} carries the rest: the macro
  # list, and where a `read_only!` guarantee would go if one is ever wanted.)
  #
  # Kiosk imposes no superclass — the include is the whole contract. Each
  # declared method is registered in {Kiosk::Server::Queries} or
  # {Kiosk::Server::Actions} and dispatched through Rails' own
  # `Controller.action(…)`, so filters, `rescue_from` and `params` all behave as
  # they do anywhere else in the app; a query runs inside the wire's GUC-scoped
  # transaction like any other statement on that connection, so per-principal
  # scoping (and RLS, where the operator opted in) applies to it. Name the class
  # in `Kiosk.configuration.handlers` — that list is how the engine finds it,
  # and since T-081 it is the only way in.
  #
  # A DESCRIPTOR SLOT MAY BE A PROC when the constraint is a fact about the
  # operator's data — `enum: -> { Category.pluck(:slug) }`. It is called when
  # the descriptor is served rather than when the class body is read (which
  # happens at `db:create` too), memoized, and refreshed on a short lifetime,
  # so adding a row publishes itself with no restart and no deploy. See
  # {Kiosk::Server::SchemaSlots}.
  #
  # A large query result opts into cursor pagination with `render_kiosk_page(rows,
  # next_cursor:, total:)` instead of `render json:`. The BODY is the same bare
  # array either way — the cursor leaves as an RFC 8288 `Link: …; rel="next"`
  # response header and the total as `X-Total-Count` (spec §8.4).
  #
  # See {Kiosk::Server::HandlerMixin} for the macros.
  module Handler
    def self.included(base)
      Kiosk::Server::HandlerMixin.install(base)
    end
  end
end
