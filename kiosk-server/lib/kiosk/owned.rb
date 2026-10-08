# frozen_string_literal: true

require "active_support/concern"
require "kiosk/server/session_context"

module Kiosk
  # The user id of the principal the wire resolved.
  def self.current_user_id = Server::SessionContext.user_id

  # `include Kiosk::Owned` in a model with a `user_id` column gives it `own`,
  # the current principal's rows: `Order.own.find(id)`.
  module Owned
    extend ActiveSupport::Concern

    included do
      scope :own, -> { where(user_id: Kiosk.current_user_id) }
    end
  end
end
