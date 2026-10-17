# frozen_string_literal: true

require 'kiosk/test_helpers/assistant'

RSpec.describe 'Kiosk::TestHelpers::Assistant::Events.payload_errors' do
  let(:document) do
    { 'events' => [{ 'name' => 'order_delivery',
                     'payload_schema' => { 'type' => 'object', 'additionalProperties' => false,
                                           'properties' => { 'status' => { 'enum' => %w[delivered] } },
                                           'required' => %w[status] } }] }
  end

  def errors(data, topic: 'order_delivery')
    Kiosk::TestHelpers::Assistant::Events.payload_errors(document, [{ 'topic' => topic, 'data' => data }])
  end

  it "is empty when every data satisfies its topic's schema, whatever the key type" do
    expect(errors({ 'status' => 'delivered' }) + errors({ status: 'delivered' })).to eq([])
  end

  it 'names the topic and the violation' do
    expect(errors({ 'status' => 'delivered', 'extra' => 1 })).to contain_exactly(start_with('order_delivery: '))
  end

  it 'reports an event whose topic the origin does not serve' do
    expect(errors({}, topic: 'nope')).to eq(['nope: this origin serves no such topic'])
  end
end
