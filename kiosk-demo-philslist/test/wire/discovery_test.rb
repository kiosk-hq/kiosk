# frozen_string_literal: true

require "test_helper"
require "kiosk/test_helpers/descriptor_examples"

class DiscoveryTest < WireTest
  test "the well-known document and the schema describe a board that takes no money" do
    kiosk  = published("/.well-known/kiosk.json")["kiosk"]
    schema = published("/kiosk/schema")

    assert_equal %w[actions queries schema], kiosk["capabilities"].sort
    assert_nil kiosk["events_url"]
    assert_equal [], schema["events"]

    assert_equal %w[browse_listings my_listings], schema["queries"].map { _1["name"] }.sort
    assert_equal %w[close_listing edit_listing post_listing], schema["actions"].map { _1["name"] }.sort
    (schema["queries"] + schema["actions"]).each do |descriptor|
      assert_predicate descriptor["description"], :present?, descriptor["name"]
    end
    [schema["queries"].find { _1["name"] == "browse_listings" }, schema["actions"].find { _1["name"] == "post_listing" }].each do |descriptor|
      %w[input_schema example_params example_row].each { assert descriptor[_1], "#{descriptor["name"]} #{_1}" }
    end

    examples = Kiosk::TestHelpers::DescriptorExamples.of(schema)
    assert_operator examples.size, :>=, 4
    assert_empty examples.filter_map(&:violation)
  end

  test "agents.json and agents.txt carry no payment terms" do
    agents_json = published("/agents.json")
    assert_empty %w[version standard site] - agents_json.keys
    assert_not agents_json.key?("payments")

    agents_txt = Net::HTTP.get(URI("#{live_url}/agents.txt"))
    assert_match(/^Authorization: agent-auth auth-md$/, agents_txt)
    assert_no_match(/^Payments:|Protocols: ap2/, agents_txt)
  end

  test "every page advertises the skill this origin pins" do
    pinned = published("/.well-known/kiosk.json").dig("kiosk", "skill", "url")
    assert_match %r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z}, pinned

    %w[/ /listings].each do |path|
      page = Net::HTTP.get_response(URI("#{live_url}#{path}"))
      assert_equal pinned, page.body[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1], path
      assert_equal pinned, page["Link"][/<([^>]*)>\s*;\s*rel="kiosk"/, 1], path
    end
  end
end
