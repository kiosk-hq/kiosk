# frozen_string_literal: true

require "test_helper"

class LinkingStory < StoryTest
  test "Alice approves the code her assistant shows her, and it books in her name" do
    newcomer = a_newcomer(as: Client)
    request  = newcomer.asks_to_be_linked(client_id: "stylish-test")
    assert newcomer.polls(request).refused?(:authorization_pending)

    signs_in(:alice).approves(request["user_code"])
    travel request["interval"] + 1
    alice = newcomer.collects(request)

    assert_equal account_of(:alice), alice.account
    assert_equal account_of(:alice), Appointment.find(alice.books["appointment_id"]).user_id
  end

  test "Alice's second assistant shares her bookings, and unlinking the first leaves the second" do
    first  = assistant_of(:alice)
    second = assistant_of(:alice)
    booked = first.books["appointment_id"]
    assert_equal [account_of(:alice)] * 2, [first.principal.user_id, second.principal.user_id]
    assert_equal [booked], second.appointments

    signs_in(:alice).unlinks(first)
    assert first.signs_back_in.refused?(:not_found)
    assert second.signs_back_in.ok?
  end

  test "Alice names her assistant and caps its spending on the assistants page" do
    linked = assistant_of(:alice)
    alice  = signs_in(:alice)
    page   = alice.visits("/kiosk/auth/assistants")
    assert_includes page.body, linked.principal.agent_id

    renamed = alice.site.post_form("/kiosk/auth/assistants/update", "authenticity_token" => alice.site.csrf_token(page.body),
                                                                    "agent_id" => linked.principal.agent_id,
                                                                    "human_label" => "Alice booking bot",
                                                                    "spending_cap_cents" => "12345")
    assert_equal "200", renamed.code
    page = alice.visits("/kiosk/auth/assistants")
    assert_includes page.body, "Alice booking bot"
    assert_includes page.body, "cap: 12345 cents"
  end
end
