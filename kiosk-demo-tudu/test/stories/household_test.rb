# frozen_string_literal: true

require "test_helper"

class HouseholdStory < StoryTest
  def news(topic, action: nil, todo: nil)
    lambda do |event|
      event["topic"] == topic.to_s &&
        (action.nil? || event.dig("data", "action") == action) &&
        (todo.nil? || event.dig("data", "todo_id") == todo)
    end
  end

  test "a housemate invited to a list joins it, and every todo says whose assistant added it" do
    alice, bob = a_member, a_member
    hike = alice.starts_a_list("Hike")
    campsite = alice.adds("Book campsite", to: hike)["todo_id"]

    joined = bob.joins(alice.invites_to(hike))
    assert_equal({ "list_id" => hike, "joined" => true }, joined.rows)
    tent = bob.adds("Bring tent", to: hike)["todo_id"]

    assert_equal "owner", alice.role_on(hike)
    assert_equal "member", bob.role_on(hike)
    assert_equal %w[member owner], alice.members_of(hike).rows.pluck("role").sort
    added_by = bob.todos_on(hike).rows.to_h { [_1["todo_id"], _1["created_by_agent_id"]] }
    assert_equal({ campsite => alice.principal.agent_id, tent => bob.principal.agent_id }, added_by)
  end

  test "a deadline is one moment, which each housemate reads on their own clock" do
    alice, bob = a_member, a_member
    hike = alice.starts_a_list
    bob.joins(alice.invites_to(hike))
    tomorrow_at_two = 1.day.from_now.in_time_zone("Europe/Istanbul").change(hour: 14).iso8601
    campsite = alice.adds("Book campsite", to: hike, due_at: tomorrow_at_two, clock: "Europe/Istanbul")["todo_id"]

    in_istanbul = alice.todo(campsite, on: hike, clock: "Europe/Istanbul")
    in_new_york = bob.todo(campsite, on: hike, clock: "America/New_York")
    assert_equal ["Europe/Istanbul", "America/New_York"], [in_istanbul["timezone"], in_new_york["timezone"]]
    assert_equal Time.iso8601(tomorrow_at_two), Time.iso8601(in_istanbul["due_at"])
    assert_equal Time.iso8601(in_istanbul["due_at"]), Time.iso8601(in_new_york["due_at"])
    assert_not_equal in_istanbul["due_at"], in_new_york["due_at"]
    assert_includes in_istanbul["due_label"], "(Europe/Istanbul)"
    assert_includes in_new_york["due_label"], "(America/New_York)"

    assert_equal ReaderClock::DEFAULT_ZONE_NAME, alice.todo(campsite, on: hike)["timezone"]
  end

  test "a deadline with no offset is refused, because each housemate would read a different moment" do
    alice = a_member
    refused = alice.adds("Book campsite", to: alice.starts_a_list, due_at: "2026-09-08T14:00:00")
    assert refused.refused?(:bad_request), refused
    assert_includes refused["detail"], "due_at"
  end

  test "the owner's assistant hears a housemate join, add, complete and leave, including what was added while it was away" do
    alice, bob = a_member, a_member
    hike = alice.starts_a_list
    watching = alice.follows(hike)
    every_list = alice.follows(topics: %w[todo])

    campsite = alice.adds("Book campsite", to: hike)["todo_id"]
    bob.joins(alice.invites_to(hike))
    assert_equal bob.account_id, watching.await(&news(:list_membership, action: "joined")).dig("data", "account_id")
    assert watching.await(&news(:todo, todo: campsite))
    heard_up_to = watching.events.pluck("id").max
    watching.close

    bobs_view = bob.follows(hike, topics: %w[todo])
    tent = bob.adds("Bring tent", to: hike)["todo_id"]

    back = alice.follows(hike, since: heard_up_to)
    assert_equal "added", back.await(&news(:todo, todo: tent)).dig("data", "action")
    assert back.events.all? { _1["id"] > heard_up_to }
    assert every_list.await(&news(:todo, todo: tent))

    assert bob.completes(campsite).ok?
    assert_equal campsite, back.await(&news(:todo, action: "completed")).dig("data", "todo_id")

    assert alice.removes(bob, from: hike).ok?
    assert_equal bob.account_id, back.await(&news(:list_membership, action: "removed")).dig("data", "account_id")
    assert_equal({ "type" => "unsubscribed", "topic" => "todo", "reason" => "reach_revoked" },
                 bobs_view.await_message(timeout: 45) { _1["type"] == "unsubscribed" })

    heard = [watching, every_list, back, bobs_view].flat_map(&:events)
    assert_equal %w[list_membership todo], heard.pluck("topic").uniq.sort
    assert_empty Kiosk::TestHelpers::Assistant::Events.payload_errors(published_schema, heard)
  end
end
