# frozen_string_literal: true

require "test_helper"
require "kiosk/test_helpers/descriptor_examples"

class DiscoveryStory < StoryTest
  test "an assistant that knows nothing finds out, without an account, what the restaurants offer and how to book" do
    kiosk  = published("/.well-known/kiosk.json")["kiosk"]
    schema = published("/kiosk/schema")

    assert_equal %w[actions queries schema], kiosk["capabilities"].sort
    assert_not kiosk.key?("events_url")
    assert_equal [], schema["events"]

    descriptors = (schema["queries"] + schema["actions"]).index_by { _1["name"] }
    %w[availability my_bookings book_table cancel_booking].each do |name|
      assert_predicate descriptors.dig(name, "description"), :present?, name
    end
    descriptors.values_at("availability", "book_table").each do |descriptor|
      %w[input_schema example_params example_row].each { assert descriptor[_1], "#{descriptor["name"]} #{_1}" }
    end

    examples = Kiosk::TestHelpers::DescriptorExamples.of(schema)
    assert_operator examples.size, :>=, 4
    assert_empty examples.filter_map(&:violation)
  end

  test "the directories assistants read say there is nothing to pay here" do
    agents_json = published("/agents.json")
    assert_empty %w[version standard site] - agents_json.keys
    assert_not agents_json.key?("payments")

    agents_txt = assistant.wire.get("/agents.txt")
    assert_equal 200, agents_txt.status
    assert_match(/^Authorization: agent-auth auth-md$/, agents_txt.raw_body)
    assert_no_match(/^Payments:|Protocols: ap2/, agents_txt.raw_body)
  end

  test "the home page and the reservations board point an assistant at the skill this origin pins" do
    pinned = published("/.well-known/kiosk.json").dig("kiosk", "skill", "url")
    assert_match %r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z}, pinned

    %w[/ /reservations].each do |path|
      page = Net::HTTP.get_response(URI("#{live_url}#{path}"))
      assert_equal pinned, page.body[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1], path
      assert_equal pinned, page["Link"][/<([^>]*)>\s*;\s*rel="kiosk"/, 1], path
    end
  end
end
