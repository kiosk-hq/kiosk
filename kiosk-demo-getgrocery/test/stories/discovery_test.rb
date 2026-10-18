# frozen_string_literal: true

require 'test_helper'
require 'kiosk/test_helpers/descriptor_examples'

class DiscoveryStory < StoryTest
  test 'an assistant that knows nothing finds out, without an account, what the shop offers and how to buy' do
    kiosk  = published('/.well-known/kiosk.json')['kiosk']
    schema = published('/kiosk/schema')

    assert_empty %w[schema queries actions pay events] - kiosk['capabilities']
    assert_match %r{\Aws://127\.0\.0\.1:\d+/kiosk/events\z}, kiosk['events_url']
    assert_equal %w[kyc_verification order_delivery payment payment_setup], schema['events'].pluck('name').sort

    queries = schema['queries'].index_by { it['name'] }
    actions = schema['actions'].index_by { it['name'] }

    assert_equal %w[catalog delivery_slots my_orders], queries.keys.sort
    assert_equal %w[create_order payment_setup request_kyc reschedule_delivery], actions.keys.sort
    queries.merge(actions).each_value { assert_predicate it['description'], :present?, it['name'] }
    [queries['catalog'], actions['create_order']].each do |descriptor|
      %w[input_schema example_params example_row].each { assert descriptor[it], "#{descriptor['name']} #{it}" }
    end

    examples = Kiosk::TestHelpers::DescriptorExamples.of(schema)

    assert_operator examples.size, :>=, 8
    assert_empty examples.filter_map(&:violation)
  end

  test 'reschedule_delivery publishes the uuid shape of the order it moves' do
    order_id = published('/kiosk/schema')['actions'].find { it['name'] == 'reschedule_delivery' }
                                                    .dig('input_schema', 'properties', 'order_id')

    assert_equal 'uuid', order_id['format']
  end

  test 'reschedule_delivery refuses an order_id that is not a uuid' do
    slot_at = DeliverySlots.starts(Date.current + 1)[0].iso8601

    ['not-a-uuid', SecureRandom.uuid.delete('-')].each do |order_id|
      assert_refused a_shopper.does(:reschedule_delivery, order_id:, slot_at:), :bad_request
    end
  end

  test 'the landing page advertises the skill this origin pins' do
    pinned = published('/.well-known/kiosk.json').dig('kiosk', 'skill', 'url')

    assert_match %r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z}, pinned

    page = Net::HTTP.get_response(URI("#{live_url}/"))

    assert_equal pinned, page.body[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]
    assert_equal pinned, page['Link'][/<([^>]*)>\s*;\s*rel="kiosk"/, 1]
  end
end
