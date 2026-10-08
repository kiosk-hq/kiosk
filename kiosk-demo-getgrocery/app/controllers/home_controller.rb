# frozen_string_literal: true

# The storefront page. It advertises the Kiosk skill to an assistant that reads it.
class HomeController < ApplicationController
  def index
    @products_in_catalog  = Product.in_stock.count
    @orders_placed        = Order.count
    @items_ordered        = OrderItem.sum(:qty)
    @deliveries_scheduled = Order.rescheduled.count

    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end
end
