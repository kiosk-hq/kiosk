# frozen_string_literal: true

# A fleet vehicle. `name` and `dock` make it concrete (e.g. "Bosphorus Cruiser"
# at "Karaköy Garage"); `kind` distinguishes the licence-free electric scooter
# ('scooter') from a combustion-engine motorcycle ('motorcycle'); when
# `needs_licence` is true, renting it is KYC-gated (age_over_18 AND licence_a)
# via the `rent_motorcycle` Action. Licence-free scooters use `start_rental`.
class Scooter < ApplicationRecord
  has_many :reservations, dependent: :destroy
end
