# frozen_string_literal: true

module Kiosk
  # The receipt the engine writes after a successful `pay` capture.
  class Settlement < ::ActiveRecord::Base
    include Kiosk::Owned

    self.table_name = "#{Kiosk.configuration.schema}.settlements"

    belongs_to :cart_mandate, class_name: "Kiosk::CartMandate", inverse_of: :settlements
  end
end
