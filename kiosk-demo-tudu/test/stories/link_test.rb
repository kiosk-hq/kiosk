# frozen_string_literal: true

require "test_helper"

class LinkStory < StoryTest
  ALICE = "00000000-0000-0000-0000-000000000001"

  setup do
    @on_its_own = a_member
    @hike = @on_its_own.starts_a_list("Hike")
  end

  # Alice, signed in on the site in her browser.
  def alice = @alice ||= a_person(email: "alice@example.com", password: "tudu-demo-password")

  def at_the_start_of_a_second = sleep(1.0 - (Time.now.to_f % 1.0))
  def owns_the_hike?(member) = member.lists.include?({ "list_id" => @hike, "title" => "Hike", "role" => "owner" })

  test "Alice links an assistant that started on its own: its list becomes hers, and every credential it held before stops working" do
    code = alice.link_code
    at_the_start_of_a_second
    issued_as_it_links = @on_its_own.with_a_fresh_credential
    linked = @on_its_own.redeems(code)
    assert_equal [ALICE, @on_its_own.principal.agent_id], [linked.account, linked.principal.agent_id]

    assert @on_its_own.asks(:my_lists).refused?(:unauthenticated)
    assert issued_as_it_links.asks(:my_lists).refused?(:unauthenticated)

    alices = @on_its_own.with_a_fresh_credential
    assert_equal ALICE, alices.account
    assert owns_the_hike?(alices)
    assert_equal ALICE, List.find(@hike).account_id
    assert_includes alice.visits("/lists").body, "Hike"

    assert_equal ALICE, alice.links(a_newcomer).account
    assert owns_the_hike?(alices), "a second assistant leaves the first one linked"
  end

  test "linking an assistant that is already Alice's again moves nothing and destroys nothing" do
    alice.links(@on_its_own)
    relinked = alice.links(@on_its_own)
    assert_equal [ALICE, @on_its_own.principal.agent_id], [relinked.account, relinked.principal.agent_id]

    assert owns_the_hike?(relinked)
    assert_equal ["Flat 3B", "Hike"], List.joins(:memberships).where(memberships: { account_id: ALICE }).pluck(:title).sort
  end

  test "the list page shows Alice who is on her list, and turns her away from a list she is not on" do
    alice.links(@on_its_own)
    page = alice.visits("/lists/#{@hike}")
    assert_equal "200", page.code
    assert_includes page.body, "Alice <span class=\"role\">(owner)</span>"

    foreign = alice.visits("/lists/#{SecureRandom.uuid}")
    assert_includes %w[302 303], foreign.code
    assert_not_includes foreign.body, "Members"
  end
end
