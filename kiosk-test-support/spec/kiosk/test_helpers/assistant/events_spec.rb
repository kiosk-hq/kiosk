# frozen_string_literal: true

require "kiosk/test_helpers/assistant"

RSpec.describe "Kiosk::TestHelpers::Assistant::Events.payload_errors" do
  let(:document) do
    { "events" => [{ "name" => "order_payment",
                     "payload_schema" => { "type" => "object", "additionalProperties" => false,
                                           "properties" => { "payment_state" => { "enum" => %w[paid] } },
                                           "required" => %w[payment_state] } }] }
  end

  def errors(data, topic: "order_payment")
    Kiosk::TestHelpers::Assistant::Events.payload_errors(document, [{ "topic" => topic, "data" => data }])
  end

  it "is empty when every data satisfies its topic's schema, whatever the key type" do
    expect(errors({ "payment_state" => "paid" }) + errors({ payment_state: "paid" })).to eq([])
  end

  it "names the topic and the violation" do
    expect(errors({ "payment_state" => "paid", "extra" => 1 })).to contain_exactly(start_with("order_payment: "))
  end

  it "reports an event whose topic the origin does not serve" do
    expect(errors({}, topic: "nope")).to eq(["nope: this origin serves no such topic"])
  end
end
