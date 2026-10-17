# frozen_string_literal: true

require 'test_helper'
require 'kiosk/test_helpers/descriptor_examples'

class DiscoveryStory < StoryTest
  test 'an assistant that knows nothing finds out, without an account, what the salon offers and how to book' do
    kiosk  = published('/.well-known/kiosk.json')['kiosk']
    schema = published('/kiosk/schema')

    assert_equal %w[actions queries schema], kiosk['capabilities'].sort
    assert_not kiosk.key?('events_url')
    assert_equal [], schema['events']

    queries = schema['queries'].index_by { it['name'] }
    actions = schema['actions'].index_by { it['name'] }
    assert_equal %w[my_appointments salon_calendar salons service_menu], queries.keys.sort
    assert_equal %w[book_appointment], actions.keys
    queries.merge(actions).each_value { assert_predicate it['description'], :present?, it['name'] }
    [queries['service_menu'], actions['book_appointment']].each do |descriptor|
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
end
