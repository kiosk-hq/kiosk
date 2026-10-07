# frozen_string_literal: true

module Kiosk
  # The receipt the engine writes after a successful `pay` capture. Read-only
  # for the operator, who reads it to answer whether an order is paid.
  class Settlement < ::ActiveRecord::Base
    self.table_name = "#{Kiosk.configuration.schema}.settlements"

    CURRENT_USER_ID = Arel.sql("#{Kiosk.configuration.schema}.current_user_id()")

    belongs_to :cart_mandate, class_name: "Kiosk::CartMandate", inverse_of: :settlements

    # The calling principal's settlements, by the same database function an RLS
    # policy uses. Raises off the wire, where it would otherwise match nothing.
    scope :of_current_principal, lambda {
      Kiosk::Server::SessionContext.require_open!
      where(arel_table[:user_id].eq(CURRENT_USER_ID))
    }
  end
end
