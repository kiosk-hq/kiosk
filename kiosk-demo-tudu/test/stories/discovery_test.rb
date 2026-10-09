# frozen_string_literal: true

require "test_helper"
require "kiosk/test_helpers/descriptor_examples"

class DiscoveryStory < StoryTest
  def get(path)
    response = Kiosk::TestHelpers::Wire.new(base_url: live_url).get(path)
    assert_equal 200, response.status, "GET #{path} with no credential"
    response
  end

  test "an assistant that knows nothing finds out, without an account, what the household lists offer and how to use them" do
    kiosk  = get("/.well-known/kiosk.json").body["kiosk"]
    schema = get("/kiosk/schema").body

    assert_equal %w[actions events queries schema], kiosk["capabilities"].sort
    assert_match %r{\Aws://127\.0\.0\.1:\d+/kiosk/events\z}, kiosk["events_url"]

    assert_empty %w[whoami my_lists list_todos list_members] - schema["queries"].pluck("name")
    assert_empty %w[create_list add_todo complete_todo invite accept_invite remove_member] - schema["actions"].pluck("name")
    (schema["queries"] + schema["actions"]).each { assert_predicate _1["description"], :present?, _1["name"] }
    [schema["queries"].find { _1["name"] == "my_lists" }, schema["actions"].find { _1["name"] == "create_list" }].each do |descriptor|
      %w[input_schema example_params example_row].each { assert descriptor[_1], "#{descriptor["name"]} #{_1}" }
    end

    assert_equal %w[list_membership todo], schema["events"].pluck("name").sort
    assert_equal %w[description name payload_schema reach], schema["events"].find { _1["name"] == "todo" }.keys.sort

    examples = Kiosk::TestHelpers::DescriptorExamples.of(schema)
    assert_operator examples.size, :>=, 4
    assert_empty examples.filter_map(&:violation)
  end

  test "nothing the household lists publish for assistants asks for a payment" do
    agents_json = get("/agents.json").body
    assert_empty %w[version standard site] - agents_json.keys
    assert_not agents_json.key?("payments")

    agents_txt = get("/agents.txt").raw_body
    assert_match(/^Authorization: agent-auth auth-md$/, agents_txt)
    assert_no_match(/^Payments:|Protocols: ap2/, agents_txt)
  end

  test "the landing page and the housemate board point an assistant at the skill this origin pins" do
    pinned = get("/.well-known/kiosk.json").body.dig("kiosk", "skill", "url")
    assert_match %r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z}, pinned

    %w[/ /shared].each do |path|
      page = get(path)
      assert_equal pinned, page.raw_body[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1], path
      assert_equal pinned, page.headers["link"][/<([^>]*)>\s*;\s*rel="kiosk"/, 1], path
    end
  end
end
