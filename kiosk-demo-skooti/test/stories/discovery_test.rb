# frozen_string_literal: true

require 'test_helper'
require 'kiosk/test_helpers/descriptor_examples'

class DiscoveryStory < StoryTest
  test 'an assistant that knows nothing finds out, without an account, what skooti rents and how to ride' do
    kiosk  = published('/.well-known/kiosk.json')['kiosk']
    schema = published('/kiosk/schema')

    assert_empty %w[schema queries actions pay events] - kiosk['capabilities']
    assert_match %r{\Aws://127\.0\.0\.1:\d+/kiosk/events\z}, kiosk['events_url']
    assert_equal %w[kyc_verification payment payment_setup], schema['events'].pluck('name').sort
    assert_equal %w[paid refunded],
                 schema['events'].find { it['name'] == 'payment' }['examples'].pluck('payment_state')

    actions = schema['actions'].index_by { it['name'] }

    %w[reserve start_rental rent_motorcycle payment_setup].each do |name|
      assert_predicate actions.dig(name, 'description'), :present?, name
    end
    [schema['queries'].find { it['name'] == 'scooters_available' }, actions['reserve']].each do |descriptor|
      %w[input_schema example_params example_row].each { assert descriptor[it], "#{descriptor['name']} #{it}" }
    end

    examples = Kiosk::TestHelpers::DescriptorExamples.of(schema)

    assert_operator examples.size, :>=, 4
    assert_empty examples.filter_map(&:violation)
  end

  test 'the landing page advertises the skill this origin pins' do
    pinned = published('/.well-known/kiosk.json').dig('kiosk', 'skill', 'url')

    assert_match %r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z}, pinned

    page = Net::HTTP.get_response(URI("#{live_url}/"))

    assert_equal pinned, page.body[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]
    assert_equal pinned, page['Link'][/<([^>]*)>\s*;\s*rel="kiosk"/, 1]
  end

  test 'an assistant reads the landing page as markdown, and a crawler finds the sitemap in robots.txt' do
    page = Net::HTTP.get_response(URI("#{live_url}/"), 'Accept' => 'text/markdown')

    assert_equal ['200', 'text/markdown'], [page.code, page.content_type]
    assert_includes page.body, '/.well-known/kiosk.json'

    sitemap_url = Net::HTTP.get(URI("#{live_url}/robots.txt"))[/^Sitemap: (\S+)$/, 1]

    assert_equal "#{live_url}/sitemap.xml", sitemap_url
    sitemap = Net::HTTP.get(URI(sitemap_url))

    assert_includes sitemap, "<loc>#{live_url}/</loc>"
  end
end
