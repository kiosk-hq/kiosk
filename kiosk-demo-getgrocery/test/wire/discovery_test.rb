# frozen_string_literal: true

require "test_helper"
require "kiosk/test_helpers/descriptor_examples"

class DiscoveryTest < WireTest
  def get(path)
    status, body = Kiosk::Redteam::Wire.new(base_url: live_url).get_json(path)
    assert_equal 200, status, "GET #{path} with no credential"
    body
  end

  test "the well-known document and the schema describe this origin without a credential" do
    kiosk  = get("/.well-known/kiosk.json")["kiosk"]
    schema = get("/kiosk/schema")

    assert_empty %w[schema queries actions pay events] - kiosk["capabilities"]
    assert_match %r{\Aws://127\.0\.0\.1:\d+/kiosk/events\z}, kiosk["events_url"]
    assert_equal %w[kyc_verification order_delivery order_payment payment_setup], schema["events"].map { _1["name"] }.sort

    queries = schema["queries"].index_by { _1["name"] }
    actions = schema["actions"].index_by { _1["name"] }
    assert_equal %w[catalog delivery_slots my_orders], queries.keys.sort
    assert_equal %w[create_order payment_setup request_kyc reschedule_delivery], actions.keys.sort
    queries.merge(actions).each_value { assert_predicate _1["description"], :present?, _1["name"] }
    [queries["catalog"], actions["create_order"]].each do |descriptor|
      %w[input_schema example_params example_row].each { assert descriptor[_1], "#{descriptor["name"]} #{_1}" }
    end

    examples = Kiosk::TestHelpers::DescriptorExamples.of(schema)
    assert_operator examples.size, :>=, 8
    assert_empty examples.filter_map(&:violation)
  end

  test "reschedule_delivery publishes the uuid shape of the order it moves" do
    order_id = get("/kiosk/schema")["actions"].find { _1["name"] == "reschedule_delivery" }
                                              .dig("input_schema", "properties", "order_id")
    assert_equal "uuid", order_id["format"]
    pattern = Regexp.new(order_id["pattern"])
    assert_match pattern, SecureRandom.uuid
    ["not-a-uuid", "'; DROP TABLE orders; --", SecureRandom.uuid.delete("-")].each { assert_no_match pattern, _1 }
  end

  test "the landing page advertises the skill this origin pins" do
    pinned = get("/.well-known/kiosk.json").dig("kiosk", "skill", "url")
    assert_match %r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z}, pinned

    page = Net::HTTP.get_response(URI("#{live_url}/"))
    assert_equal pinned, page.body[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]
    assert_equal pinned, page["Link"][/<([^>]*)>\s*;\s*rel="kiosk"/, 1]
  end
end
