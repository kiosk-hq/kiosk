# frozen_string_literal: true

module Admin
  # The operator's recent orders. Public on this demo, so addresses are masked.
  class OrdersController < ActionController::Base
    layout "admin"

    def index
      @orders = Order.with_settlement(Kiosk::Settlement.all)
                     .includes(order_items: :product)
                     .order(created_at: :desc)
                     .limit(50)
    end
  end
end
