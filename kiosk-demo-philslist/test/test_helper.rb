# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Runs the block as `user`, the way the wire runs a handler.
    def as(user, &)
      identity = Kiosk::Identity.new(user_id: user.id, role: nil, actor: "human")
      Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: identity, &)
    end
  end
end
