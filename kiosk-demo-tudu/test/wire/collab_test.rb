# frozen_string_literal: true

require "test_helper"

class CollabTest < WireTest
  setup do
    @alice   = register
    @bob     = register
    @list_id = create_list(@alice)
  end

  def add_todo(who, zone: nil, **args)
    added = client.run(who, name: "add_todo", list_id: @list_id, headers: clock(zone), **args)
    assert_equal 200, added.status, added.body
    added.body["todo_id"]
  end

  def todos(who, zone: nil) = client.query(who, name: "list_todos", list_id: @list_id, headers: clock(zone)).body.index_by { _1["todo_id"] }
  def clock(zone) = zone ? { "Kiosk-Timezone" => zone } : {}
  def stream(who) = Kiosk::TestHelpers::Assistant::Events.new(base_url: live_url, token: who.token)

  test "an invited assistant joins the list, and each todo names the assistant that added it" do
    alices_todo = add_todo(@alice, title: "Book campsite")
    assert_equal({ "list_id" => @list_id, "joined" => true }, join(@bob, invite(@alice, @list_id)))
    bobs_todo = add_todo(@bob, title: "Bring tent")

    roles = ->(who) { client.query(who, name: "my_lists").body.to_h { [_1["list_id"], _1["role"]] } }
    assert_equal "owner",  roles.(@alice)[@list_id]
    assert_equal "member", roles.(@bob)[@list_id]

    attribution = todos(@bob).transform_values { _1["created_by_agent_id"] }
    assert_equal({ alices_todo => @alice.agent_id, bobs_todo => @bob.agent_id }, attribution)
    members = client.query(@alice, name: "list_members", list_id: @list_id).body
    assert_equal %w[member owner], members.map { _1["role"] }.sort
  end

  test "a deadline is one instant, read on each member's own clock" do
    join(@bob, invite(@alice, @list_id))
    tomorrow_at_two = 1.day.from_now.in_time_zone("Europe/Istanbul").change(hour: 14).iso8601
    todo_id = add_todo(@alice, zone: "Europe/Istanbul", title: "Book campsite", due_at: tomorrow_at_two)

    alices = todos(@alice, zone: "Europe/Istanbul")[todo_id]
    bobs   = todos(@bob, zone: "America/New_York")[todo_id]
    assert_equal ["Europe/Istanbul", "America/New_York"], [alices["timezone"], bobs["timezone"]]
    assert_equal Time.iso8601(tomorrow_at_two), Time.iso8601(alices["due_at"])
    assert_equal Time.iso8601(alices["due_at"]), Time.iso8601(bobs["due_at"])
    assert_not_equal alices["due_at"], bobs["due_at"]
    assert_includes alices["due_label"], "(Europe/Istanbul)"
    assert_includes bobs["due_label"], "(America/New_York)"
    assert_equal ReaderClock::DEFAULT_ZONE_NAME, todos(@alice)[todo_id]["timezone"]

    zoneless = client.run(@alice, name: "add_todo", list_id: @list_id, title: "no zone", due_at: "2026-09-08T14:00:00")
    assert_equal [400, "bad_request"], [zoneless.status, zoneless.body["code"]]
    assert_includes zoneless.body["detail"], "due_at"
  end

  test "the owner's assistant is told of a member joining, adding, completing and being removed" do
    live = stream(@alice)
    live.subscribe("todo", subject: @list_id)
    live.subscribe("list_membership", subject: @list_id)
    any_list = stream(@alice)
    any_list.subscribe("todo")

    alices_todo = add_todo(@alice, title: "Book campsite")
    join(@bob, invite(@alice, @list_id))
    joined = live.await { _1["topic"] == "list_membership" && _1.dig("data", "action") == "joined" }
    assert_equal @bob.user_id, joined.dig("data", "account_id")
    assert live.await { _1["topic"] == "todo" && _1.dig("data", "todo_id") == alices_todo }
    cursor = live.events.map { _1["id"] }.max
    live.close

    bobs_stream = stream(@bob)
    bobs_stream.subscribe("todo", subject: @list_id)
    bobs_todo = add_todo(@bob, title: "Bring tent")

    back = stream(@alice)
    back.subscribe("todo", subject: @list_id, since: cursor)
    back.subscribe("list_membership", subject: @list_id)
    bobs = ->(event) { event["topic"] == "todo" && event.dig("data", "todo_id") == bobs_todo }
    assert_equal "added", back.await(&bobs).dig("data", "action")
    assert back.events.all? { _1["id"] > cursor }
    assert any_list.await(&bobs)

    assert_equal 200, client.run(@bob, name: "complete_todo", todo_id: alices_todo).status
    completed = back.await { _1["topic"] == "todo" && _1.dig("data", "action") == "completed" }
    assert_equal alices_todo, completed.dig("data", "todo_id")

    assert_equal 200, client.run(@alice, name: "remove_member", list_id: @list_id, account_id: @bob.user_id).status
    removed = back.await { _1["topic"] == "list_membership" && _1.dig("data", "action") == "removed" }
    assert_equal @bob.user_id, removed.dig("data", "account_id")
    revoked = bobs_stream.await_message(timeout: 45) { _1["type"] == "unsubscribed" }
    assert_equal({ "type" => "unsubscribed", "topic" => "todo", "reason" => "reach_revoked" }, revoked)

    delivered = [live, any_list, back, bobs_stream].flat_map(&:events)
    [any_list, back, bobs_stream].each(&:close)
    assert_equal %w[list_membership todo], delivered.map { _1["topic"] }.uniq.sort
    assert_empty Kiosk::TestHelpers::Assistant::Events.payload_errors(wire.get_json("/kiosk/schema").last, delivered)
  end
end
