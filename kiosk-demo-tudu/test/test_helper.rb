# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"
require "kiosk/story_test"

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

# A household member's AI assistant: starts lists, invites housemates, adds and
# ticks off todos, and is told what changes on the lists it shares.
class Member < Kiosk::TestHelpers::Customer
  def account_id = principal.user_id

  def starts_a_list(title = "Hike") = does(:create_list, title:)["list_id"]
  def invites_to(list) = does(:invite, list_id: list)["code"]
  def joins(code) = does(:accept_invite, code:)
  def removes(member, from:) = does(:remove_member, list_id: from, account_id: member.account_id)

  def lists = asks(:my_lists).rows
  def list_ids = lists.pluck("list_id")
  def role_on(list) = lists.find { _1["list_id"] == list }&.fetch("role")
  def members_of(list) = asks(:list_members, list_id: list)

  # `clock` is the zone the member's person lives in.
  def adds(title, to:, clock: nil, **) = does(:add_todo, list_id: to, title:, headers: zone(clock), **)
  def todos_on(list, clock: nil) = asks(:list_todos, list_id: list, headers: zone(clock))
  def todo(id, on:, clock: nil) = todos_on(on, clock:).rows.find { _1["todo_id"] == id }
  def completes(todo) = does(:complete_todo, todo_id: todo)

  # A connection of its own to the origin's news on `list`, or on every list.
  def follows(list = nil, topics: %w[todo list_membership], since: nil)
    @assistant.events(principal).tap do |news|
      topics.each { news.subscribe(_1, **{ subject: list, since: }.compact) }
      (@connections ||= []) << news
    end
  end

  def leaves
    super
    @connections&.each(&:close)
  end

  private

  def zone(clock) = clock ? { "Kiosk-Timezone" => clock } : {}
end

class StoryTest < Kiosk::StoryTest
  def a_member = a_customer(as: Member)

  def published_schema = Kiosk::TestHelpers::Wire.new(base_url: live_url).get_json("/kiosk/schema").last
end
