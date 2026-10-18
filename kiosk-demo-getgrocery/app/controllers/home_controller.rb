# frozen_string_literal: true

# The storefront page. It advertises the Kiosk skill to an assistant that reads it.
class HomeController < ApplicationController
  include Kiosk::SkillLink

  def index
    @products_in_catalog  = Product.count
    @orders_placed        = Order.count
    @items_ordered        = OrderItem.sum(:qty)
    @deliveries_scheduled = Order.awaiting_courier.count
  end
end
