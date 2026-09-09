# frozen_string_literal: true

# The provider's public storefront. Its only Kiosk-specific job is to ADVERTISE
# the agent affordance: a visible "Agents → Kiosk here" hook + a machine-readable
# <link rel="kiosk"> so an assistant scanning the page discovers it can transact.
class HomeController < ApplicationController
  def index
    # Live DOMAIN activity counters, rendered server-side on page load (a refresh
    # is enough — no JS polling). These read getgrocery's OWN tables. Catalog =
    # in-stock products (out-of-stock is hidden from the catalog query).
    #
    # THE DELIVERY COUNTER READS THE CONSTANT, NOT A LITERAL. A status literal
    # written here is a value only this line believes in: this origin is
    # reseeded additively, so a counter naming a status the current wire no
    # longer writes keeps reading a frozen number off old rows while every
    # delivery the wire actually moves stays invisible to it, and a stat
    # presented as live activity that no current request can change is worse
    # than no stat.
    # {Order::ALREADY_SCHEDULED} is the same predicate the admin badge and the
    # one-reschedule-per-order rule already use, so a third spelling of "this
    # delivery has been booked" cannot drift away from the other two.
    @products_in_catalog  = Product.where("stock > 0").count
    @orders_placed        = Order.count
    @items_ordered        = OrderItem.sum(:qty)
    @deliveries_scheduled = Order.where(status: Order::ALREADY_SCHEDULED).count

    # Set a Link header too, so a header-only agent finds the well-known.
    # The url is `Kiosk.configuration.skill_url` — the VERSIONED cut this
    # operator pins, identical to the one `/.well-known/kiosk.json` carries
    # under `skill`, never the mutable skill.md alias. Derived rather than
    # restated so a cut is re-pinned in ONE place, the initializer.
    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end
end
