# frozen_string_literal: true

# The storefront page. It advertises the Kiosk skill to an assistant that reads it.
class HomeController < ApplicationController
  include Kiosk::SkillLink

  # An assistant that ranks Markdown first in Accept (q-value, then order) reads the page as Markdown.
  # Rails alone answers HTML to every Accept that also lists */*.
  before_action only: :index do
    response.set_header('Vary', 'Accept')
    request.format = :md if request.accepts.first == Mime[:md]
  end

  def index
    @products_in_catalog  = Product.count
    @orders_placed        = Order.count
    @items_ordered        = OrderItem.sum(:qty)
    @deliveries_scheduled = Order.awaiting_courier.count
  end
end
