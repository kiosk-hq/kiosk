# frozen_string_literal: true

# The provider's public storefront. Its only Kiosk-specific job is to ADVERTISE
# the agent affordance: a visible "Agents → Kiosk here" hook + a machine-readable
# <link rel="kiosk"> so an assistant scanning the page discovers it can transact.
class HomeController < ActionController::Base
  def index
    # Live DOMAIN activity counters, rendered server-side on page load (a refresh
    # is enough — no JS polling). These read getgrocery's OWN tables, not
    # telemetry. Catalog = in-stock products (out-of-stock is hidden from the
    # catalog query); a scheduled order is a booked delivery slot.
    @products_in_catalog  = Product.where("stock > 0").count
    @orders_placed        = Order.count
    @items_ordered        = OrderItem.sum(:qty)
    @deliveries_scheduled = Order.where(status: "scheduled").count

    # Set a Link header too, so a header-only agent finds the well-known.
    response.set_header("Link", '<https://kiosk.tech/skill.md>; rel="kiosk"')
  end
end
