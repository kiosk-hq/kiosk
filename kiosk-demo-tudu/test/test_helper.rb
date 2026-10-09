# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"
require "kiosk/test_helpers/live_server"
require "kiosk/redteam"

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

# Drives this origin over HTTP as an assistant does.
class WireTest < ActiveSupport::TestCase
  include Kiosk::TestHelpers::LiveServer

  ALICE_ID = "00000000-0000-0000-0000-000000000001"

  def client = @client ||= Kiosk::Redteam::Client.new(base_url: live_url)
  def wire = @wire ||= Kiosk::Redteam::Wire.new(base_url: live_url)

  def register = client.register!(name: "assistant")

  def create_list(owner, title = "Hike")
    created = client.run(owner, name: "create_list", title:)
    assert_equal 200, created.status, created.body
    created.body["list_id"]
  end

  def invite(owner, list_id)
    invited = client.run(owner, name: "invite", list_id:)
    assert_equal 200, invited.status, invited.body
    invited.body["code"]
  end

  def join(member, code)
    accepted = client.run(member, name: "accept_invite", code:)
    assert_equal 200, accepted.status, accepted.body
    accepted.body
  end

  def list_ids(principal) = client.query(principal, name: "my_lists").body.map { _1["list_id"] }
end
