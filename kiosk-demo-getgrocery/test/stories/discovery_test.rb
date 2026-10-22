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

  test 'the landing page advertises the skill this origin pins and its api-catalog' do
    pinned = published('/.well-known/kiosk.json').dig('kiosk', 'skill', 'url')

    assert_match %r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z}, pinned

    page = Net::HTTP.get_response(URI("#{live_url}/"))

    assert_equal pinned, page.body[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]
    assert_equal pinned, page['Link'][/<([^>]*)>\s*;\s*rel="kiosk"/, 1]
    assert_equal '/.well-known/api-catalog', page['Link'][/<([^>]*)>\s*;\s*rel="api-catalog"/, 1]
  end

  test 'an assistant reads the landing page as markdown, and a crawler finds the sitemap in robots.txt' do
    page = Net::HTTP.get_response(URI("#{live_url}/"), 'Accept' => 'text/markdown')

    assert_equal ['200', 'text/markdown'], [page.code, page.content_type]
    assert_includes page.body, '/.well-known/kiosk.json'

    sitemap = Net::HTTP.get(URI("#{live_url}/robots.txt"))[/^Sitemap: (\S+)$/, 1]

    assert_equal "#{live_url}/sitemap.xml", sitemap
    assert_includes Net::HTTP.get(URI(sitemap)), "<loc>#{live_url}/</loc>"
  end

  test 'the landing page answers the type that Accept ranks first, and a browser gets HTML' do
    { 'text/markdown, */*' => 'text/markdown', 'text/markdown;q=1.0, */*;q=0.1' => 'text/markdown',
      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' => 'text/html' }.each do |accept, type|
      page = Net::HTTP.get_response(URI("#{live_url}/"), 'Accept' => accept)

      assert_equal ['200', type, 'Accept'], [page.code, page.content_type, page['Vary']], accept
    end
  end
end
