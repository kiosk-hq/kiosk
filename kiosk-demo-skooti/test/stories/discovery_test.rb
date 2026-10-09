# frozen_string_literal: true

require "test_helper"
require "kiosk/test_helpers/descriptor_examples"

class DiscoveryStory < StoryTest
  test "an assistant that knows nothing finds out, without an account, what skooti rents and how to ride" do
    kiosk  = published("/.well-known/kiosk.json")["kiosk"]
    schema = published("/kiosk/schema")

    assert_empty %w[schema queries actions pay events] - kiosk["capabilities"]
    assert_match %r{\Aws://127\.0\.0\.1:\d+/kiosk/events\z}, kiosk["events_url"]
    assert_equal %w[booking_payment kyc_verification payment_setup], schema["events"].map { _1["name"] }.sort

    actions = schema["actions"].index_by { _1["name"] }
    %w[reserve start_rental rent_motorcycle payment_setup].each do |name|
      assert_predicate actions.dig(name, "description"), :present?, name
    end
    [schema["queries"].find { _1["name"] == "scooters_available" }, actions["reserve"]].each do |descriptor|
      %w[input_schema example_params example_row].each { assert descriptor[_1], "#{descriptor["name"]} #{_1}" }
    end

    examples = Kiosk::TestHelpers::DescriptorExamples.of(schema)
    assert_operator examples.size, :>=, 4
    assert_empty examples.filter_map(&:violation)
  end

  test "the landing page advertises the skill this origin pins" do
    pinned = published("/.well-known/kiosk.json").dig("kiosk", "skill", "url")
    assert_match %r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z}, pinned

    page = Net::HTTP.get_response(URI("#{live_url}/"))
    assert_equal pinned, page.body[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]
    assert_equal pinned, page["Link"][/<([^>]*)>\s*;\s*rel="kiosk"/, 1]
  end
end
