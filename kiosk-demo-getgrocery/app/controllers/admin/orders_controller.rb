# frozen_string_literal: true

module Admin
  # The operator's read-only list of recent orders.
  #
  # No authentication — public by design: an operator-view showcase on a sandbox
  # with synthetic data, so delivery addresses are masked on the page.
  class OrdersController < ActionController::Base
    layout "admin"

    RECENT = 50

    def index
      # Every principal's settlements: this is the operator's view, not one
      # assistant's. The wire's `my_orders` passes its caller's own.
      @orders = Order.with_settled_currency(Kiosk::Settlement.all)
                     .includes(order_items: :product)
                     .order(created_at: :desc)
                     .limit(RECENT)
    end
  end
end
