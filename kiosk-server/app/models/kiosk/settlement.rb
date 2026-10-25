# frozen_string_literal: true

module Kiosk
  # The receipt the engine writes after a successful `pay` capture.
  class Settlement < Server::ApplicationRecord
    include Kiosk::Owned

    belongs_to :checkout_mandate, class_name: 'Kiosk::CheckoutMandate', inverse_of: :settlements
  end
end
