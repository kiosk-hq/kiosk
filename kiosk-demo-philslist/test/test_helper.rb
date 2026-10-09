# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"
require "kiosk/test_helpers/live_server"
require "kiosk/test_helpers/assistant"

# The categories enum is read from the table, which every wire test reseeds.
Kiosk::Server::SchemaSlots.refresh_seconds = 0

module ActiveSupport
  class TestCase
    # Runs the block as `user`, the way the wire runs a handler.
    def as(user, &)
      identity = Kiosk::Identity.new(user_id: user.id, role: nil, actor: "human")
      Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: identity, &)
    end
  end
end

# Drives this origin over HTTP as an assistant does.
class WireTest < ActiveSupport::TestCase
  include Kiosk::TestHelpers::LiveServer

  PASSWORD = "philslist-demo-password"

  def client = @client ||= Kiosk::TestHelpers::Assistant.new(base_url: live_url)

  def register = client.register!

  def post_listing(seller, **listing)
    posted = client.run(seller, name: "post_listing", category_slug: "furniture", title: "Bookshelf", body: "Pine", **listing)
    assert_equal 200, posted.status, posted.body
    posted.body["listing_id"]
  end

  def published(path)
    status, body = Kiosk::TestHelpers::Wire.new(base_url: live_url).get_json(path)
    assert_equal 200, status, "GET #{path} with no credential"
    body
  end
end
