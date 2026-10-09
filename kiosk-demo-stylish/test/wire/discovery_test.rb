# frozen_string_literal: true

require "test_helper"
require "kiosk/test_helpers/descriptor_examples"

class DiscoveryTest < WireTest
  def get(path)
    status, body = Kiosk::TestHelpers::Wire.new(base_url: live_url).get_json(path)
    assert_equal 200, status, "GET #{path} with no credential"
    body
  end

  test "the well-known document and the schema describe this origin without a credential" do
    kiosk  = get("/.well-known/kiosk.json")["kiosk"]
    schema = get("/kiosk/schema")

    assert_equal %w[actions queries schema], kiosk["capabilities"].sort
    assert_not kiosk.key?("events_url")
    assert_equal [], schema["events"]

    assert_equal %w[availability my_appointments salon_calendar salons service_menu], schema["queries"].map { _1["name"] }.sort
    assert_equal %w[book_appointment], schema["actions"].map { _1["name"] }
    (schema["queries"] + schema["actions"]).each do |descriptor|
      assert_predicate descriptor["description"], :present?, descriptor["name"]
    end
    [schema["queries"].find { _1["name"] == "service_menu" }, schema["actions"].first].each do |descriptor|
      %w[input_schema example_params example_row].each { assert descriptor[_1], "#{descriptor["name"]} #{_1}" }
    end

    examples = Kiosk::TestHelpers::DescriptorExamples.of(schema)
    assert_operator examples.size, :>=, 6
    assert_empty examples.filter_map(&:violation)
  end

  test "the landing page advertises the skill this origin pins" do
    pinned = get("/.well-known/kiosk.json").dig("kiosk", "skill", "url")
    assert_match %r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z}, pinned

    page = Net::HTTP.get_response(URI("#{live_url}/"))
    assert_equal pinned, page.body[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]
    assert_equal pinned, page["Link"][/<([^>]*)>\s*;\s*rel="kiosk"/, 1]
  end
end
