# frozen_string_literal: true

require "test_helper"

class AssistantClaimedTest < ActiveSupport::TestCase
  setup { @alice, @bob, @list = household }

  def claimed(from, to) = Kiosk.configuration.assistant_claimed.call(agent: nil, from:, to:)

  test "a headless account's lists and memberships move to the human who claims its assistant" do
    headless = User.create!
    hike = List.create!(account: headless, title: "Hike", memberships: [Membership.new(account: headless, role: :owner)])
    @list.memberships.create!(account: headless, role: :member)

    claimed(headless, @alice)

    assert_equal @alice.id, hike.reload.account_id
    assert_equal({ hike.id => "owner", @list.id => "owner" }, Membership.where(account: @alice).pluck(:list_id, :role).to_h)
    assert_not Membership.exists?(account: headless)
  end
end
