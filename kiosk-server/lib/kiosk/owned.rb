# frozen_string_literal: true

require 'active_support/concern'

module Kiosk
  # `include Kiosk::Owned` in a model with a `user_id` column gives it `own`,
  # the current principal's rows: `Order.own.find(id)`, and `owned_by(user_id)`,
  # one principal's rows. `user_id` holds `Kiosk.current_user_id`.
  module Owned
    extend ActiveSupport::Concern

    included do
      scope :owned_by, ->(user_id) { where(user_id:) }
      scope :own, -> { owned_by(Kiosk.current_user_id) }
    end
  end
end
