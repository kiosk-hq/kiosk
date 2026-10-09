# frozen_string_literal: true

require "story_helper"
require "kiosk/test_helpers/descriptor_examples"

RSpec.describe "Discovering the hotel", type: :story do
  it "an assistant that knows nothing finds out, without an account, what the hotel offers and how to book" do
    kiosk  = published("/.well-known/kiosk.json")["kiosk"]
    schema = published("/kiosk/schema")

    expect(kiosk["capabilities"]).to include("schema", "queries", "actions", "pay", "events")
    expect(kiosk["events_url"]).to match(%r{\Aws://127\.0\.0\.1:\d+/kiosk/events\z})
    expect(schema["events"].map { _1["name"] }.sort).to eq(%w[booking_confirmation booking_payment payment_setup])

    queries = schema["queries"].index_by { _1["name"] }
    actions = schema["actions"].index_by { _1["name"] }
    %w[properties availability my_bookings search_hotels hotel_detail].each do |name|
      expect(queries.dig(name, "description")).to be_present, name
    end
    %w[reserve_room confirm_booking payment_setup].each do |name|
      expect(actions.dig(name, "description")).to be_present, name
    end
    queries.values_at("search_hotels", "hotel_detail").each do |descriptor|
      expect(descriptor.values_at("input_schema", "example_params", "example_row")).to all(be_present)
    end

    examples = Kiosk::TestHelpers::DescriptorExamples.of(schema)
    expect(examples.size).to be >= 4
    expect(examples.filter_map(&:violation)).to be_empty
  end

  it "the landing page advertises the skill this origin pins" do
    pinned = published("/.well-known/kiosk.json").dig("kiosk", "skill", "url")
    expect(pinned).to match(%r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z})

    page = Net::HTTP.get_response(URI("#{live_url}/"))
    expect(page.body[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]).to eq(pinned)
    expect(page["Link"][/<([^>]*)>\s*;\s*rel="kiosk"/, 1]).to eq(pinned)
  end
end
