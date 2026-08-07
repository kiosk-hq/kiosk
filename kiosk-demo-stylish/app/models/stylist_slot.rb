# frozen_string_literal: true

# An evergreen open slot: ONE named stylist is available to book ONE service at
# a captured EUR price. This is AVAILABILITY (not a dated appointment), so it
# never goes stale — the salon's structure is seven of these (one per stylist),
# always bookable. Real bookings land in Appointment and accumulate against the
# stylist; the forecast sums slot prices and folds those bookings in.
class StylistSlot < ApplicationRecord
  belongs_to :stylist, class_name: "User"
  belongs_to :salon
  belongs_to :service

  def price_eur = Service.format_eur(price_cents)
end
