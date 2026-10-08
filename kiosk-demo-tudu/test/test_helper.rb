# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    def as(user, &)
      identity = Kiosk::Identity.new(user_id: user.id, role: "customer", actor: "human")
      Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: identity, &)
    end

    def household
      alice = User.create!(display_name: "Alice")
      bob   = User.create!(display_name: "Bob")
      list  = List.create!(account: alice, title: "Flat 3B",
                           memberships: [Membership.new(account: alice, role: :owner),
                                         Membership.new(account: bob, role: :member)])
      [alice, bob, list]
    end
  end
end
